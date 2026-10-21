#pragma once
#include <array>
namespace character {
// 平台层先翻译成项目按键枚举；领域层不认识Win32 VK值。
enum class Key {Forward,Backward,Left,Right,Up,Down,Fast,Pause,Step,Reset,Escape,Count};
struct InputSnapshot {
    std::array<bool,unsigned(Key::Count)> held{},pressed{};
    float mouseX=0,mouseY=0;bool focused=true,looking=false;
};
struct CameraIntent {float forward=0,right=0,up=0,lookX=0,lookY=0;bool fast=false,reset=false;};
struct AppCommands {bool togglePause=false,singleStep=false,exit=false;};
struct Actions {CameraIntent camera;AppCommands app;};
inline Actions MapActions(const InputSnapshot& input){
    Actions result;if(!input.focused)return result;
    auto held=[&](Key key){return input.held[unsigned(key)]?1.f:0.f;};
    auto pressed=[&](Key key){return input.pressed[unsigned(key)];};
    result.camera.forward=held(Key::Forward)-held(Key::Backward);result.camera.right=held(Key::Right)-held(Key::Left);
    result.camera.up=held(Key::Up)-held(Key::Down);result.camera.fast=held(Key::Fast)!=0;result.camera.reset=pressed(Key::Reset);
    if(input.looking){result.camera.lookX=input.mouseX;result.camera.lookY=input.mouseY;}
    result.app={pressed(Key::Pause),pressed(Key::Step),pressed(Key::Escape)};return result;
}
}
