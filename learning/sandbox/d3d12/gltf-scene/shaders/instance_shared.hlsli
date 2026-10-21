struct ObjectRecord {
    row_major float4x4 world;
    uint material;
    uint node;
    uint mesh;
    uint padding;
};
StructuredBuffer<ObjectRecord> objects : register(t1);
cbuffer Camera : register(b0) {
    row_major float4x4 viewProjection;
    row_major float4x4 inverseViewProjection;
    uint width,height,pad0,pad1;
};
