/* Copyright (c) 2015-2017, EPFL/Blue Brain Project
 * All rights reserved. Do not distribute without permission.
 * Responsible Author: Cyrille Favreau <cyrille.favreau@epfl.ch>
 *
 * Based on OSPRay implementation
 *
 * This file is part of Brayns <https://github.com/BlueBrain/Brayns>
 *
 * This library is free software; you can redistribute it and/or modify it under
 * the terms of the GNU Lesser General Public License version 3.0 as published
 * by the Free Software Foundation.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

// Brayns
#include <plugins/engines/ospray/ispc/render/utils/AbstractRenderer.ih>

// needs to be the same in MorphologyLoader.cpp
uniform const uniform float OFFSET_MAGIC = 1e6;

struct SimulationRenderer
{
    AbstractRenderer abstract;

    Model* simulationModel;
    uniform float* uniform simulationData;
    uint64 simulationDataSize;
    float threshold;
    float detectionDistance;
};

struct ShadingAttributes
{
    const uniform SimulationRenderer* uniform self;
    varying DifferentialGeometry* dg;
    vec3f origin;
    vec3f normal;
    vec3f reflectedNormal;
    float refraction;
    float reflection;
    float opacity;
    vec3f diffuseColor;
    vec3f specularColor;
    float specularExponent;
    vec3f lightEmissionColor;
    float lightEmissionIntensity;
    bool castSimulationData;
    vec4f simulationColor;
    vec3f indirectColor;
    float indirectIntensity;
    vec3f volumeColor;
    float volumeIntensity;
    vec3f shadingContribution;
    vec3f finalContribution;
};

inline void initializeShadingAttributes(
    const uniform SimulationRenderer* uniform self,
    ShadingAttributes& attributes)
{
    attributes.self = self;
    attributes.dg = 0;

    // Final contribution
    attributes.finalContribution = make_vec3f(0.f);

    // Simulation contribution
    attributes.castSimulationData = true;
    attributes.simulationColor = make_vec4f(0.f);

    // Indirect light contribution
    attributes.indirectColor = make_vec3f(0.f);
    attributes.indirectIntensity = 0.f;

    // Light emission
    attributes.lightEmissionColor = make_vec3f(0.f);
    attributes.lightEmissionIntensity = 0.f;

    // Volume
    attributes.volumeColor = make_vec3f(0.f);
    attributes.volumeIntensity = 0.f;

    // Specular color
    attributes.specularColor = make_vec3f(0.f);
    attributes.specularExponent = 0.f;

    // Shading contribution
    attributes.shadingContribution = make_vec3f(0.f);

    // Other attributes
    attributes.reflection = 0.f;
    attributes.refraction = 1.f;
    attributes.opacity = 0.f;
}

inline void setGeometryShadingAttributes(
    const uniform SimulationRenderer* uniform self, DifferentialGeometry& dg,
    varying ScreenSample& sample, Ray& ray, ShadingAttributes& attributes)
{
    attributes.dg = &dg;

    // Intersection point with geometry
    attributes.origin = dg.P;

    // Shading normal
    attributes.normal = dg.Ns;

    // Reflected shading normal
    attributes.reflectedNormal =
        ray.dir - 2.f * dot(ray.dir, attributes.normal) * attributes.normal;

    // Process material attributes
    const uniform Material* material = dg.material;
    const uniform ExtendedOBJMaterial* objMaterial =
        (const uniform ExtendedOBJMaterial*)material;
    if (!objMaterial)
    {
        // Diffuse color
        attributes.diffuseColor = make_vec3f(dg.color);

        // if no material is defined, localOpacity is stored in the alpha
        // component of the RGBA color
        attributes.opacity = dg.color.w;
        return;
    }

    foreach_unique(mat in objMaterial)
    {
        // Glossiness
        if (mat->glossiness < 1.f)
        {
            const vec3f randomNormal =
                (1.f - mat->glossiness) *
                getRandomVector(sample, attributes.normal,
                                self->abstract.randomNumber);
            attributes.normal = normalize(attributes.normal + randomNormal);
        }

        // Refraction index
        attributes.refraction = mat->refraction;

        // Opacity
        if (valid(mat->map_d))
            attributes.opacity = mat->d * get1f(mat->map_d, dg.st, 1.f);
        else
            attributes.opacity = mat->d;

        // Diffuse color
        attributes.diffuseColor = mat->Kd * make_vec3f(dg.color);
        if (valid(mat->map_Kd))
        {
            const vec4f diffuseColorFromMap = get4f(mat->map_Kd, dg.st);
            attributes.diffuseColor =
                attributes.diffuseColor * make_vec3f(diffuseColorFromMap);
            attributes.opacity = diffuseColorFromMap.w;
        }

        // Specular color
        if (valid(mat->map_Ks))
            attributes.specularColor =
                max(attributes.specularColor,
                    mat->Ks * get3f(mat->map_Ks, dg.st, make_vec3f(1.f)));
        else
            attributes.specularColor = max(attributes.specularColor, mat->Ks);

        // Specular exponent
        if (valid(mat->map_Ns))
            attributes.specularExponent =
                max(attributes.specularExponent,
                    mat->Ns * get1f(mat->map_Ns, dg.st, 1.f));
        else
            attributes.specularExponent =
                max(attributes.specularExponent, mat->Ns);

        // Light emission intensity
        attributes.lightEmissionIntensity += mat->a;
        attributes.lightEmissionColor = attributes.diffuseColor;

        // Normal mapping
        if (valid(mat->map_Bump))
        {
            const vec3f n = get3f(mat->map_Bump, dg.st, make_vec3f(0.f)) - 0.5f;
            attributes.normal.x -= n.x;
            attributes.normal.y -= n.y;
        }

        // Reflection index
        attributes.reflection = mat->reflection;
        if (valid(mat->map_reflection))
        {
            const vec3f value =
                get3f(mat->map_reflection, dg.st, make_vec3f(0.f));
            attributes.reflection *= (value.x + value.y + value.z) / 3.f;
        }

        // Cast simulation data
        attributes.castSimulationData = mat->castSimulationData;
    }

    // Update reflected shading normal
    attributes.reflectedNormal =
        ray.dir - 2.f * dot(ray.dir, attributes.normal) * attributes.normal;
}

/**
  The processSimulationContribution reads simulation value
  from the simulation data buffer.
  The geometry contains the offset of the buffer in it's X texture coordinates.
  The value from the simulation data buffer is then converted into a color,
  according to the colormap.
  */
inline void processSimulationValue(ShadingAttributes& attributes,
                                   varying DifferentialGeometry* dg)
{
    float value = 0.f;
    const uint64 index = (uint64)(dg->st.x * OFFSET_MAGIC) << 32 |
                         (uint32)(dg->st.y * OFFSET_MAGIC);

    if (index < attributes.self->simulationDataSize)
        value = attributes.self->simulationData[index];
    else
        // Value offset is out of range, return error color
        return;

    if (value < attributes.self->threshold)
        return;

    // Normalize the value according colormap size
    const float normalizedValue =
        (value - attributes.self->abstract.colorMapMinValue) /
        attributes.self->abstract.colorMapRange;

    const uint32 lookupIndex = max(0.f, min(normalizedValue, 1.f)) *
                               (attributes.self->abstract.colorMapSize - 1);

    attributes.simulationColor =
        attributes.self->abstract.colorMap[lookupIndex];

    if (attributes.self->abstract.emissionIntensitiesMap)
        attributes.lightEmissionColor =
            attributes.lightEmissionColor +
            attributes.self->abstract.emissionIntensitiesMap[lookupIndex];
}

/**
  The purpose of the processSimulationContribution function is to retreive the
  value of the simulation from a secondary model attached to the OSPRay scene.
  The geometry is defined by the primary model, but the shading is computed
  according to a second, non-visible model that contains the simulation values.
  In the case of circuit rendering for examples, neurons are meshes, and
  compartment reports are cones and cylinders that are inside the neuron. When
  an intersection is found at the surface of a mesh, a ray defined by the
  intersection point and the opposite normal to the surface is launched to hit
  the secondary model. When the secondary model is intersected, the simulation
  value is retrieved and used to shade the surface of the mesh.
*/
inline void processSimulationContribution(varying ScreenSample& sample,
                                          ShadingAttributes& attributes,
                                          const int materialID)
{
    if (!attributes.castSimulationData)
        return;

    if (!attributes.self->simulationModel)
    {
        processSimulationValue(attributes, attributes.dg);
        return;
    }

    // Get simulation color from simulation model
    Ray colorRay;
    colorRay.org = attributes.origin;
    colorRay.dir = getRandomVector(sample, attributes.normal * -1.f,
                                   attributes.self->abstract.randomNumber);
    colorRay.t0 = 0.f;
    colorRay.time = inf;
    colorRay.t = attributes.self->detectionDistance;
    colorRay.primID = -1;
    colorRay.geomID = -1;
    colorRay.instID = -1;

    // Trace ray to hit the simulation model
    traceRay(attributes.self->simulationModel, colorRay);

    if (colorRay.geomID < 0)
        attributes.simulationColor = make_vec4f(0.f);
    else
    {
        // Intersection found. Simulation ray hit a primitive
        varying DifferentialGeometry colorDg;
        postIntersect(attributes.self->simulationModel, colorDg, colorRay,
                      DG_MATERIALID | DG_TEXCOORD);
        if (materialID == colorDg.materialID && attributes.self->simulationData)
            // The mesh and it's corresponding representation in the
            // simulation model must use the same material ID. This is to
            // make sure that one neuron is not shaded with the simulation
            // value of another neuron.
            processSimulationValue(attributes, &colorDg);
    }
}

inline void processBackgroundColor(varying ScreenSample& sample,
                                   ShadingAttributes& attributes)
{
    // No intersection. Return volume contribution + skybox color
    const vec4f bgColor = skyboxMapping((Renderer*)attributes.self, sample.ray,
                                        attributes.self->abstract.numMaterials,
                                        attributes.self->abstract.materials);

    attributes.shadingContribution = make_vec3f(bgColor);
}

inline void computeIndirectShading(varying ScreenSample& sample,
                                   ShadingAttributes& attributes)

{
    if (attributes.self->abstract.ambientOcclusionStrength == 0.f ||
        attributes.lightEmissionIntensity > 0.01f)
        return;

    DifferentialGeometry dg;
    indirectShading(&(attributes.self->abstract), sample, attributes.origin,
                    attributes.normal, dg, attributes.indirectColor,
                    attributes.indirectIntensity);
}

inline void processLightShading(DifferentialGeometry& dg,
                                varying ScreenSample& sample,
                                ShadingAttributes& attributes)
{
    // Shading for all lights defined in the scene
    attributes.shadingContribution = make_vec3f(0.f);
    for (uniform int i = 0; attributes.self->abstract.lights &&
                            i < attributes.self->abstract.numLights;
         ++i)
    {
        const uniform Light* uniform light =
            attributes.self->abstract.lights[i];
        const vec2f s = make_vec2f(0.5f);
        const varying Light_SampleRes lightSample = light->sample(light, dg, s);
        const vec3f radiance = lightSample.weight;
        const varying vec3f lightDirection = lightSample.dir;

        if (reduce_max(radiance) > 0.f)
        {
            float cosNL = 1.f;
            vec3f specularColor = make_vec3f(0.f);

            // Phong + Blinn shading
            const bool shadingEnabled =
                attributes.self->abstract.shadingEnabled;
            if (shadingEnabled)
            {
                cosNL = dot(lightDirection, attributes.normal);

                // Specular color
                const float cosLR =
                    dot(lightDirection, attributes.reflectedNormal);
                specularColor = attributes.specularColor *
                                powf(cosLR, attributes.specularExponent);
            }

            // Process shadows
            const bool shadowsEnabled =
                attributes.self->abstract.shadows > 0.f &&
                attributes.lightEmissionIntensity < 0.01f;
            const float alpha =
                shadowsEnabled
                    ? shadedLightIntensity(&(attributes.self->abstract), sample,
                                           attributes.origin, attributes.normal,
                                           lightDirection)
                    : 1.f;
            attributes.shadingContribution =
                attributes.shadingContribution + specularColor +
                alpha * cosNL * attributes.diffuseColor;
        }
    }
}

inline void processElectronShading(varying ScreenSample& sample,
                                   ShadingAttributes& attributes)
{
    const vec3f viewer = normalize(sample.ray.org - attributes.origin);
    const float el = max(0.f, dot(viewer, attributes.normal));
    const float cosNL = 1.f - el;
    attributes.shadingContribution = attributes.diffuseColor * cosNL;
}

inline void processVolumeContribution(varying ScreenSample& sample,
                                      ShadingAttributes& attributes, Ray& ray)
{
    if (attributes.self->abstract.volumeData)
    {
        const vec4f volumetricValue =
            getVolumeContribution(&(attributes.self->abstract), ray, sample);
        attributes.volumeColor = make_vec3f(volumetricValue);
        attributes.volumeIntensity = volumetricValue.w;
    }
}

inline void processFinalContribution(ShadingAttributes& attributes)
{
    // Indirect light contribution
    const vec3f indirectContribution =
        attributes.indirectColor * attributes.indirectIntensity;

    // Simulation contribution
    const vec3f simulationColor = make_vec3f(attributes.simulationColor);
    float alpha = attributes.simulationColor.w;

    // Surface + volume final contribution
    vec3f totalContributions =
        (attributes.shadingContribution + simulationColor) * (1.f - alpha) +
        attributes.shadingContribution * simulationColor * alpha +
        indirectContribution;

    // Volume contribution
    vec4f dst =
        make_vec4f(totalContributions, 1.f - attributes.volumeIntensity);
    const vec4f src =
        make_vec4f(attributes.volumeColor, attributes.volumeIntensity);
    composite(src, dst, attributes.self->abstract.volumeSamplesPerRay);

    // Light emission contribution
    const vec3f finalContribution =
        make_vec3f(dst) +
        attributes.lightEmissionIntensity * attributes.lightEmissionColor;

    // Store final contribution
    attributes.finalContribution.x = max(0.f, min(1.f, finalContribution.x));
    attributes.finalContribution.y = max(0.f, min(1.f, finalContribution.y));
    attributes.finalContribution.z = max(0.f, min(1.f, finalContribution.z));
}

inline vec3f SimulationRenderer_shadeRay(
    const uniform SimulationRenderer* uniform self,
    varying ScreenSample& sample)
{
    Ray ray = sample.ray;
    vec3f color = make_vec3f(0.f);

    float pathOpacity = 1.f;
    unsigned int depth = 0;
    float oldlocalRefraction = 1.f;
    bool moreRebounds = true;

    sample.z = inf;
    sample.alpha = 0.f;

    while (moreRebounds && depth < NB_MAX_REBOUNDS)
    {
        // Shading attributes store all color contributions for the current ray
        ShadingAttributes attributes;
        initializeShadingAttributes(self, attributes);

        // Trace ray
        traceRay(self->abstract.super.model, ray);

        if (ray.geomID < 0)
        {
            // Background contribution
            processBackgroundColor(sample, attributes);

            // Volume contribution
            processVolumeContribution(sample, attributes, ray);

            // No Geometry intersection. No need to iterate more
            moreRebounds = false;
        }
        else
        {
            // Get intersection information
            DifferentialGeometry dg;
            postIntersect(self->abstract.super.model, dg, ray,
                          DG_NG | DG_NS | DG_NORMALIZE | DG_FACEFORWARD |
                              DG_MATERIALID | DG_COLOR | DG_TEXCOORD);

            // Z-Depth
            if (depth == 0)
                sample.z = ray.t;

            // Initialize geometry shading attributes
            setGeometryShadingAttributes(self, dg, sample, ray, attributes);

            if (attributes.opacity == 0.f)
            {
                ray.t0 = ray.t + self->abstract.super.epsilon;
                ray.t = inf;
                ray.primID = -1;
                ray.geomID = -1;
                ray.instID = -1;
                continue;
            }

            // Compute simulation contribution
            processSimulationContribution(sample, attributes, dg.materialID);

            if (attributes.opacity > 0.01f && moreRebounds)
            {
                // Compute indirect lightening contribution
                computeIndirectShading(sample, attributes);

                // Compute surface shading
                if (self->abstract.electronShadingEnabled)
                    processElectronShading(sample, attributes);
                else
                    processLightShading(dg, sample, attributes);

                // Compute volume contribution
                processVolumeContribution(sample, attributes, ray);
            }
            else
                // Fully transparent object. Ignore intersection
                ray.t0 = ray.t + 1.f;
        }

        // Combine all contributions
        processFinalContribution(attributes);

        color = attributes.finalContribution * pathOpacity +
                color * (1.f - pathOpacity);

        // Prepare ray for next iteration
        float alpha = 1.f;
        if (attributes.opacity < 1.f)
        {
            // Refraction
            const float angle = dot(ray.dir, attributes.normal);
            if (abs(attributes.refraction - oldlocalRefraction) < 0.001f)
                if (angle > 0.f)
                    attributes.refraction = 1.f;

            ray.t0 = 0.f;
            ray.dir =
                refractedVector(ray.dir, attributes.normal, oldlocalRefraction,
                                attributes.refraction);
            ray.org =
                attributes.origin + self->abstract.super.epsilon * ray.dir;

            pathOpacity *= (1.f - attributes.opacity);
            oldlocalRefraction = attributes.refraction;
            ++depth;
        }
        else if (attributes.reflection > 0.f)
        {
            // Reflection
            ray.t0 = 0.f;
            ray.dir = attributes.reflectedNormal;
            ray.org = attributes.origin +
                      self->abstract.super.epsilon * attributes.reflectedNormal;
            pathOpacity *= attributes.reflection;
            ++depth;
        }
        else
            moreRebounds = false;

        // Alpha
        sample.alpha += attributes.opacity;

        ray.t = inf;
        ray.primID = -1;
        ray.geomID = -1;
        ray.instID = -1;
    }

    return color;
}

void SimulationRenderer_renderSample(uniform Renderer* uniform _self,
                                     void* uniform perFrameData,
                                     varying ScreenSample& sample)
{
    uniform SimulationRenderer* uniform self =
        (uniform SimulationRenderer * uniform)_self;
    sample.ray.time = infinity;
    sample.rgb = SimulationRenderer_shadeRay(self, sample);
}

// Exports (called from C++)
export void* uniform SimulationRenderer_create(void* uniform cppE)
{
    uniform SimulationRenderer* uniform self =
        uniform new uniform SimulationRenderer;
    Renderer_Constructor(&self->abstract.super, cppE);
    self->abstract.super.renderSample = SimulationRenderer_renderSample;
    return self;
}

export void SimulationRenderer_set(
    void* uniform _self, void* uniform simulationModel,
    const uniform vec3f& bgColor, const uniform float& shadows,
    const uniform float& softShadows,
    const uniform float& ambientOcclusionStrength,
    const uniform float& ambientOcclusionDistance,
    const uniform bool& shadingEnabled, const uniform int& randomNumber,
    const uniform float& timestamp, const uniform int& spp,
    const uniform bool& electronShadingEnabled, void** uniform lights,
    const uniform int32 numLights, void** uniform materials,
    const uniform int32 numMaterials, uniform uint8* uniform volumeData,
    const uniform vec3i& volumeDimensions,
    const uniform vec3f& volumeElementSpacing,
    const uniform vec3f& volumeOffset, const uniform float& volumeEpsilon,
    const uniform int32& volumeSamplesPerRay,
    uniform float* uniform simulationData,
    const uniform uint64& simulationDataSize, uniform vec4f* uniform colormap,
    uniform vec3f* uniform emissionIntensitiesMap,
    const uniform int32 colorMapSize, const uniform float& colorMapMinValue,
    const uniform float& colorMapRange, const uniform float& threshold,
    const uniform float& detectionDistance)
{
    uniform SimulationRenderer* uniform self =
        (uniform SimulationRenderer * uniform)_self;

    self->abstract.bgColor = bgColor;
    self->abstract.shadows = shadows;
    self->abstract.softShadows = softShadows;
    self->abstract.ambientOcclusionStrength = ambientOcclusionStrength;
    self->abstract.ambientOcclusionDistance = ambientOcclusionDistance;
    self->abstract.shadingEnabled = shadingEnabled;
    self->abstract.randomNumber = randomNumber;
    self->abstract.timestamp = timestamp;
    self->abstract.spp = spp;
    self->abstract.electronShadingEnabled = electronShadingEnabled;

    self->abstract.lights = (const uniform Light* uniform* uniform)lights;
    self->abstract.numLights = numLights;

    self->abstract.materials =
        (const uniform ExtendedOBJMaterial* uniform* uniform)materials;
    self->abstract.numMaterials = numMaterials;

    self->abstract.volumeData = (uniform uint8 * uniform)volumeData;
    self->abstract.volumeDimensions = volumeDimensions;
    self->abstract.volumeElementSpacing = volumeElementSpacing;
    self->abstract.volumeOffset = volumeOffset;
    self->abstract.volumeEpsilon = volumeEpsilon;
    self->abstract.volumeSamplesPerRay = volumeSamplesPerRay;

    const uniform vec3f diag =
        make_vec3f(volumeDimensions) * volumeElementSpacing;
    self->abstract.volumeDiag = max(diag.x, max(diag.y, diag.z));

    self->abstract.colorMap = (uniform vec4f * uniform)colormap;
    self->abstract.emissionIntensitiesMap =
        (uniform vec3f * uniform)emissionIntensitiesMap;
    self->abstract.colorMapSize = colorMapSize;
    self->abstract.colorMapMinValue = colorMapMinValue;
    self->abstract.colorMapRange = colorMapRange;

    self->simulationModel = (uniform Model * uniform)simulationModel;
    self->simulationData = (uniform float* uniform)simulationData;
    self->simulationDataSize = simulationDataSize;

    self->threshold = threshold;
    self->detectionDistance = detectionDistance;
}
