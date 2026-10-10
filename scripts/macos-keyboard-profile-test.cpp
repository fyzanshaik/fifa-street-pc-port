// Real MnK driver, isolated synthetic events; no game or native window input.
#include <rex/cvar.h>
#include <rex/input/mnk/mnk_input_driver.h>
#include <rex/ui/keybinds.h>
#include <cstdio>
#include <vector>
using namespace rex;
struct Expect {const char* key;uint16_t buttons=0;uint8_t lt=0,rt=0;int16_t lx=0,ly=0,rx=0,ry=0;};
int main(int argc,char** argv) {
  if(argc!=2) return 2;
  cvar::LoadConfig(argv[1]);cvar::SetFlagByName("mnk_mode","true");
  cvar::SetFlagByName("mnk_mouse","false");
  input::mnk::MnkInputDriver driver(nullptr,0);std::vector<input::DeviceInfo> devices;
  driver.EnumerateDevices(devices);if(devices.size()!=1)return 1;
  auto key=[&](const char* token,bool down) {
    ui::KeyEvent e(nullptr,ui::ParseVirtualKey(token),1,false,false,false,false,false);
    if(down)driver.OnKeyDown(e);else driver.OnKeyUp(e);
  };
  auto check=[&](const Expect& e) {
    input::X_INPUT_STATE s{};
    if(driver.GetDeviceState(devices[0].id,&s)!=X_ERROR_SUCCESS)return false;
    const auto& g=s.gamepad;
    return g.buttons==e.buttons && g.left_trigger==e.lt && g.right_trigger==e.rt &&
           g.thumb_lx==e.lx && g.thumb_ly==e.ly && g.thumb_rx==e.rx && g.thumb_ry==e.ry;
  };
  const Expect cases[]={
    {"Up",0,0,0,0,32767},{"Down",0,0,0,0,-32767},
    {"Left",0,0,0,-32767},{"Right",0,0,0,32767},
    {"Space",0x1000},{"D",0x2000},{"Backspace",0x2000},
    {"A",0x4000},{"S",0x8000},{"Q",0,255},{"E",0,0,255},
    {"W",0x0100},{"R",0x0200},{"Z",0x0040},{"C",0x0080},
    {"I",0,0,0,0,0,0,32767},{"K",0,0,0,0,0,0,-32767},
    {"J",0,0,0,0,0,-32767},{"L",0,0,0,0,0,32767},
    {"T",0x0001},{"G",0x0002},{"F",0x0004},{"H",0x0008},
    {"Tab",0x0020},{"Return",0x0010}};
  for(const auto& e:cases) {
    key(e.key,true);if(!check(e)) {std::printf("FAIL: %s drives wrong controller state\n",e.key);return 1;}
    key(e.key,false);if(!check({"neutral"})) {std::puts("FAIL: release isn't neutral");return 1;}
  }
  key("Right",true);key("E",true);key("Space",true);
  if(!check({"combo",0x1000,0,255,32767})) {
    std::puts("FAIL: move + sprint + pass interfere");return 1;
  }
  key("Right",false);key("E",false);key("Space",false);
  key("Return",true);key("D",true);
  if(!check({"exit chord",0x2010})) {std::puts("FAIL: exit shortcut mapping");return 1;}
  std::puts("PASS: 25 bindings, releases, move+sprint+pass and exit chord through real MnK driver");
}
