#ifndef LATIOS_VERTEX_SKINNING_INCLUDED
#define LATIOS_VERTEX_SKINNING_INCLUDED

// Can be a float3x4, a QVVS, or a DQS
struct TransformUnion
{
    float4 a;
    float4 b;
    float4 c;
};

struct Qvvs
{
    float4 rotation;
    float4 position;
    float4 stretchScale;
};

// Dual Quaternion with Scale
struct Dqs
{
    float4 r; // real
    float4 d; // dual
    float4 scale;
};

#if defined(UNITY_DOTS_INSTANCING_ENABLED)
uniform StructuredBuffer<TransformUnion> _latiosBindPoses;
uniform ByteAddressBuffer                _latiosBoneTransforms;


TransformUnion readBone(uint absoluteBoneIndex)
{
    TransformUnion result = (TransformUnion)0;
    result.a = asfloat(_latiosBoneTransforms.Load4(absoluteBoneIndex * 48));
    result.b = asfloat(_latiosBoneTransforms.Load4(absoluteBoneIndex * 48 + 16));
    result.c = asfloat(_latiosBoneTransforms.Load4(absoluteBoneIndex * 48 + 32));
    return result;
}
#endif

void fromQuaternion(float4 v, out float3 c0, out float3 c1, out float3 c2)
{
    float4 v2 = v + v;

    uint3 npn = uint3(0x80000000, 0x00000000, 0x80000000);
    uint3 nnp = uint3(0x80000000, 0x80000000, 0x00000000);
    uint3 pnn = uint3(0x00000000, 0x80000000, 0x80000000);
    c0 = v2.y * asfloat(asuint(v.yxw) ^ npn) - v2.z * asfloat(asuint(v.zwx) ^ pnn) + float3(1, 0, 0);
    c1 = v2.z * asfloat(asuint(v.wzy) ^ nnp) - v2.x * asfloat(asuint(v.yxw) ^ npn) + float3(0, 1, 0);
    c2 = v2.x * asfloat(asuint(v.zwx) ^ pnn) - v2.y * asfloat(asuint(v.wzy) ^ nnp) + float3(0, 0, 1);
}

float4 mulQuatQuat(float4 a, float4 b)
{
    return float4(a.wwww * b + (a.xyzx * b.wwwx + a.yzxy * b.zxyy) * float4(1, 1, 1, -1) - a.zxyz * b.yzxz);
}

float3x4 qvvsToMatrix(Qvvs qvvs)
{
    float3 scale = qvvs.stretchScale.xyz * qvvs.stretchScale.w;
    float3 c0 = 0;
    float3 c1 = 0;
    float3 c2 = 0;
    fromQuaternion(qvvs.rotation, c0, c1, c2);
    c0 *= scale.x;
    c1 *= scale.y;
    c2 *= scale.z;
    return float3x4(
        c0.x, c1.x, c2.x, qvvs.position.x,
        c0.y, c1.y, c2.y, qvvs.position.y,
        c0.z, c1.z, c2.z, qvvs.position.z
        );
}

float3x4 transformUnionMatrixToMatrix(TransformUnion transform)
{
    return float3x4(
        transform.a.x, transform.a.w, transform.b.z, transform.c.y,
        transform.a.y, transform.b.x, transform.b.w, transform.c.z,
        transform.a.z, transform.b.y, transform.c.x, transform.c.w
        );
}

Dqs transformUnionDqsToDqs(TransformUnion transform)
{
    Dqs result = (Dqs)0;
    result.r = transform.a;
    result.d = transform.b;
    result.scale.xyz = transform.c.xyz;
    return result;
}

float3x4 mul3x4(float3x4 a, float3x4 b)
{
    float3 a0 = a._m00_m01_m02;
    float3 a1 = a._m10_m11_m12;
    float3 a2 = a._m20_m21_m22;

    float3 b0 = b._m00_m10_m20;
    float3 b1 = b._m01_m11_m21;
    float3 b2 = b._m02_m12_m22;
    float3 b3 = b._m03_m13_m23;

    return float3x4(
        dot(a0, b0), dot(a0, b1), dot(a0, b2), dot(a0, b3) + a._m03,
        dot(a1, b0), dot(a1, b1), dot(a1, b2), dot(a1, b3) + a._m13,
        dot(a2, b0), dot(a2, b1), dot(a2, b2), dot(a2, b3) + a._m23
        );
}

void vertexSkinMatrix(uint4 boneIndices, float4 boneWeights, uint skeletonBase, inout float3 position, inout float3 normal, inout float3 tangent)
{
#if defined(UNITY_DOTS_INSTANCING_ENABLED)
    float3x4 mat = transformUnionMatrixToMatrix(readBone(skeletonBase + boneIndices.x)) * boneWeights.x;

    if (boneWeights.y > 0.0)
    {
        mat += transformUnionMatrixToMatrix(readBone(skeletonBase + boneIndices.y)) * boneWeights.y;
    }
    if (boneWeights.z > 0.0)
    {
        mat += transformUnionMatrixToMatrix(readBone(skeletonBase + boneIndices.z)) * boneWeights.z;
    }
    if (boneWeights.w > 0.0 && boneWeights.w < 0.5)
    {
        mat += transformUnionMatrixToMatrix(readBone(skeletonBase + boneIndices.w)) * boneWeights.w;
    }
    
    position = mul(mat, float4(position, 1)).xyz;
    normal = mul(mat, float4(normal, 0)).xyz;
    tangent = mul(mat, float4(tangent, 0)).xyz;
#endif
}

void vertexSkinDqs(uint4 boneIndices, float4 boneWeights, uint2 skeletonBase, inout float3 position, inout float3 normal, inout float3 tangent)
{
#if defined(UNITY_DOTS_INSTANCING_ENABLED)
    {
        // Reminder: Bindposes do not have bone offsets, as they come from the mesh.
        Dqs dqs = transformUnionDqsToDqs(_latiosBindPoses[skeletonBase.y + boneIndices.x]);
        float4 bindposeReal = dqs.r * boneWeights.x;
        float4 bindposeDual = dqs.d * boneWeights.x;
        float3 localScale = dqs.scale;
        float4 firstBoneRot = dqs.r;

        if (boneWeights.y > 0.0)
        {
            dqs = transformUnionDqsToDqs(_latiosBindPoses[skeletonBase.y + boneIndices.y]);
            localScale += dqs.scale.xyz * boneWeights.y;
            if (dot(dqs.r, firstBoneRot) < 0)
                boneWeights.y = -boneWeights.y;
            bindposeReal += dqs.r * boneWeights.y;
            bindposeDual += dqs.d * boneWeights.y;
        }
        if (boneWeights.z > 0.0)
        {
            dqs = transformUnionDqsToDqs(_latiosBindPoses[skeletonBase.y + boneIndices.z]);
            localScale += dqs.scale.xyz * boneWeights.z;
            if (dot(dqs.r, firstBoneRot) < 0)
                boneWeights.z = -boneWeights.z;
            bindposeReal += dqs.r * boneWeights.z;
            bindposeDual += dqs.d * boneWeights.z;
        }
        if (boneWeights.w > 0.0 && boneWeights.w < 0.5)
        {
            dqs = transformUnionDqsToDqs(_latiosBindPoses[skeletonBase.y + boneIndices.w]);
            localScale += dqs.scale.xyz * boneWeights.w;
            if (dot(dqs.r, firstBoneRot) < 0)
                boneWeights.w = -boneWeights.w;
            bindposeReal += dqs.r * boneWeights.w;
            bindposeDual += dqs.d * boneWeights.w;
        }

        {
            // Todo: Deform via DQS directly?
            float mag = length(bindposeReal);
            bindposeReal /= mag;
            bindposeDual /= mag;

            Qvvs bpQvvs = (Qvvs)0;
            bpQvvs.rotation = bindposeReal;
            bindposeReal.xyz = -bindposeReal.xyz;
            bpQvvs.position.xyz = mulQuatQuat(2 * bindposeDual, bindposeReal).xyz;
            bpQvvs.stretchScale = float4(1, 1, 1, 1);

            float3x4 deform = qvvsToMatrix(bpQvvs);
            float3x4 scale = float3x4(
                localScale.x, 0, 0, 0,
                0, localScale.y, 0, 0,
                0, 0, localScale.z, 0
                );
            deform = mul3x4(scale, deform);

            position = mul(deform, float4(position, 1));
            normal = mul(deform, float4(normal, 0));
            tangent = mul(deform, float4(tangent, 0));
        }
    }

    {
        Dqs dqs = transformUnionDqsToDqs(readBone(skeletonBase.x + boneIndices.x));
        float4 worldReal = dqs.r * boneWeights.x;
        float4 worldDual = dqs.d * boneWeights.x;
        float3 localScale = dqs.scale;
        float4 firstBoneRot = dqs.r;

        if (boneWeights.y > 0.0)
        {
            dqs = transformUnionDqsToDqs(readBone(skeletonBase.x + boneIndices.y));
            localScale += dqs.scale.xyz * boneWeights.y;
            if (dot(dqs.r, firstBoneRot) < 0)
                boneWeights.y = -boneWeights.y;
            worldReal += dqs.r * boneWeights.y;
            worldDual += dqs.d * boneWeights.y;
        }
        if (boneWeights.z > 0.0)
        {
            dqs = transformUnionDqsToDqs(readBone(skeletonBase.x + boneIndices.z));
            localScale += dqs.scale.xyz * boneWeights.z;
            if (dot(dqs.r, firstBoneRot) < 0)
                boneWeights.z = -boneWeights.z;
            worldReal += dqs.r * boneWeights.z;
            worldDual += dqs.d * boneWeights.z;
        }
        if (boneWeights.w > 0.0 && boneWeights.w < 0.5)
        {
            dqs = transformUnionDqsToDqs(readBone(skeletonBase.x + boneIndices.w));
            localScale += dqs.scale.xyz * boneWeights.w;
            if (dot(dqs.r, firstBoneRot) < 0)
                boneWeights.w = -boneWeights.w;
            worldReal += dqs.r * boneWeights.w;
            worldDual += dqs.d * boneWeights.w;
        }

        {
            float mag = length(worldReal);
            worldReal /= mag;
            worldDual /= mag;

            Qvvs worldQvvs = (Qvvs)0;
            worldQvvs.rotation = worldReal;
            worldReal.xyz = -worldReal.xyz;
            worldQvvs.position.xyz = mulQuatQuat(2 * worldDual, worldReal).xyz;
            worldQvvs.stretchScale = float4(localScale, 1);

            float3x4 deform = qvvsToMatrix(worldQvvs);

            position = mul(deform, float4(position, 1));
            normal = mul(deform, float4(normal, 0));
            tangent = mul(deform, float4(tangent, 0));
        }
    }
#endif
}

#endif
