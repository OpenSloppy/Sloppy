#include <metal_stdlib>
using namespace metal;

// Native translation of the generated Aura WebGL/GLSL shader (aura.html).
// Keep its volume integration, color, bloom, and grain equations in sync.
struct OrbUniforms {
    float2 resolution;
    float time, level, bass, mid, treble, padding;
};

vertex float4 desktopOrbVertex(uint id [[vertex_id]]) {
    const float2 positions[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return float4(positions[id], 0, 1);
}

float orbHash(float3 p) { p=fract(p*.3183099+float3(.17,.31,.53)); p*=17.; return fract(p.x*p.y*p.z*(p.x+p.y+p.z)); }
float orbNoise(float3 p) {
  float3 i=floor(p), f=fract(p); f=f*f*(3.-2.*f);
  return mix(mix(mix(orbHash(i),orbHash(i+float3(1,0,0)),f.x),mix(orbHash(i+float3(0,1,0)),orbHash(i+float3(1,1,0)),f.x),f.y),
             mix(mix(orbHash(i+float3(0,0,1)),orbHash(i+float3(1,0,1)),f.x),mix(orbHash(i+float3(0,1,1)),orbHash(i+float3(1,1,1)),f.x),f.y),f.z);
}
float2 orbRotate(float2 p, float a) { float c=cos(a),s=sin(a); return float2(c*p.x+s*p.y,-s*p.x+c*p.y); }
fragment float4 desktopOrbFragment(float4 position [[position]], constant OrbUniforms &u [[buffer(0)]]) {
  float2 coordinates=float2(position.x,u.resolution.y-position.y);
  float2 uv=(coordinates-.5*u.resolution)/min(u.resolution.x,u.resolution.y)*2.;
  float t=u.time*.23;
  float breath=1.+.025*sin(u.time*.8)+u.level*.105+u.bass*.045;
  float2 q=uv/(.70*breath);
  float r=length(q);
  float3 light=float3(0.);
  float a=atan2(q.y,q.x);
  float halo=exp(-pow(r/1.03,4.))* .09 + exp(-pow((r-.94)/.24,2.))*.13;
  float3 haloColor=mix(float3(.20,.35,.75),float3(.64,.54,.77),.5+.5*sin(a*2.-t));
  light+=haloColor*halo;
  // Integrate luminous flowing ribbons through a soft spherical volume.
  float depth=sqrt(max(0.,1.12-r*r));
  for(int i=0;i<20;i++) {
    float z=(-1.+2.*(float(i)+.5)/20.)*depth;
    float3 p=float3(q,z);
    p.xz=orbRotate(p.xz,t*.37);
    p.xy=orbRotate(p.xy,t*.20);
    float radius=length(p);
    float n=orbNoise(p*2.9+float3(t*.55,-t*.38,t*.25));
    float n2=orbNoise(p*5.6-float3(t*.2,t*.45,0.));
    float angle=atan2(p.y,p.x);
    float flow=angle*4.+p.z*3.2+radius*2.8-t*1.35+(n-.5)*4.2;
    float ribbon=pow(.5+.5*sin(flow),5.);
    float secondary=pow(.5+.5*sin(angle*3.-p.z*4.5-t*.8+n2*3.),9.);
    float envelope=1.-smoothstep(.72,1.08+(n-.5)*.09,radius);
    float cloud=.22+.78*n;
  float density=(ribbon*.92+secondary*.32+.12)*envelope*cloud;
    float hue=.5+.5*sin(flow*.45+p.z*2.+t*.7+n*3.);
    float3 blue=float3(.055,.25,.96), cyan=float3(.16,.88,1.02), pearl=float3(.87,.77,.96);
    float3 color=mix(blue,cyan,smoothstep(.15,.76,hue));
    color=mix(color,pearl,pow(.5+.5*sin(p.y*3.+p.z*2.+t*.9+n2*2.),6.)*.75);
    color=mix(color,float3(.58,.38,1.),u.treble*.23);
    light+=color*density*depth*.13*(1.+u.level*.95+u.mid*.35);
  }
  // A diffuse luminous core and optical bloom, without a hard silhouette.
  float core=exp(-r*r*15.)*(.27+.09*sin(t*2.)+u.level*.2);
  light+=float3(.39,.75,1.)*core;
  float veil=exp(-pow(r/.86,6.))*.12;
  light+=float3(.10,.24,.72)*veil;
  float beamAngle=a+t*.6+.45*sin(r*3.-t)+.22*sin(a*3.+t);
  float beams=pow(.5+.5*sin(beamAngle*5.),4.);
  light+=float3(.18,.66,.91)*beams*exp(-r*r*2.8)*(1.-smoothstep(.8,1.1,r))*.31;
  light=1.-exp(-light*3.4);
  float grain=(orbHash(float3(coordinates,7.))-.5)*.018;
  light=max(float3(0.),light+grain*min(1.,halo*3.+length(light)));
  float alpha=clamp(max(max(light.r,light.g),light.b)*1.3,0.,1.);
  // Fade both premultiplied color and alpha before reaching the canvas/ring edge.
  float edgeFade=1.-smoothstep(.68,1.,length(uv));
  return float4(light,alpha)*edgeFade;
}
