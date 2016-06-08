/* Copyright (c) 2011-2016, EPFL/Blue Brain Project
 * All rights reserved. Do not distribute without permission.
 * Responsible Author: Cyrille Favreau <cyrille.favreau@epfl.ch>
 *
 * This file is part of BRayns
 */

#ifndef PRIMITIVE_H
#define PRIMITIVE_H

#include "Geometry.h"

#include <brayns/api.h>
#include <brayns/common/types.h>
#include <memory>
#include <map>

namespace brayns
{

class Primitive: public Geometry
{
public:
    BRAYNS_API Primitive( const size_t materialId, const float timestamp = 0.f);
    BRAYNS_API virtual ~Primitive() {}

    BRAYNS_API size_t getMaterialId() const { return _materialId; }
    BRAYNS_API float getTimestamp() const { return _timestamp; }

    BRAYNS_API virtual size_t serializeData(floats& serializedData) = 0;
    BRAYNS_API static size_t getSerializationSize()
    { return _serializationSize; }


protected:
    static size_t _serializationSize;
    size_t _materialId;
    float _timestamp;
};

}

#endif // PRIMITIVE_H
