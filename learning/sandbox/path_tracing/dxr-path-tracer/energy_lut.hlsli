// t7根SRV指向float数组：头4个float；129行×257列E；最后129个平均值。
// 宿主Load先验收格式、大小与值域，再InstanceUpload；GPU不把头当动态可任意变更布局。
StructuredBuffer<float> energyLut:register(t7);
static const uint EnergyRows=129,EnergyColumns=257,EnergyAverage=4+129*257;
float EnergyCosine(uint j){float u=float(j)/256;return u*u*u*u;}
void EnergyRow(float roughness,out uint row,out float t){
    float x=clamp(log2(roughness*roughness/1e-4)/log2(1e4)*128,0,128);
    row=min((uint)x,127);t=x-row;
}
float EnergyCurve(uint row,uint col,float t){uint index=4+row*EnergyColumns+col;return lerp(energyLut[index],energyLut[index+1],t);}
float EnergyAt(float roughness,float cosine){
    float c=saturate(cosine);if(roughness*roughness<=1e-4){float t=1-c;return .04+.96*t*t*t*t*t;}
    uint row;float tr;EnergyRow(roughness,row,tr);
    uint col=min((uint)(sqrt(sqrt(c))*256),255);float c0=EnergyCosine(col),c1=EnergyCosine(col+1);
    float tc=(c-c0)/(c1-c0);return lerp(EnergyCurve(row,col,tc),EnergyCurve(row+1,col,tc),tr);
}
float EnergyMean(float roughness){
    if(roughness*roughness<=1e-4)return 3.0/35.0;
    uint row;float t;EnergyRow(roughness,row,t);return lerp(energyLut[EnergyAverage+row],energyLut[EnergyAverage+row+1],t);
}
