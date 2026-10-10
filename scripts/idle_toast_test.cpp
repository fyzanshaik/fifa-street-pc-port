// Integration check through the real toast -> ImGui -> Presenter -> Window
// repaint chain. Only platform/GPU drawing are replaced; no native window/game.
#include <rex/cvar.h>
#include <rex/ui/imgui_drawer.h>
#include <rex/ui/imgui_dialog.h>
#include <rex/ui/overlay/achievement_toast.h>
#include <rex/ui/overlay/achievement_notification_dispatch.h>
#include <rex/ui/windowed_app_context.h>
#include <cstdio>
#include <thread>
#include <rex/input/input_system.h>
#include <rex/input/device_assignment.h>
#include <rex/input/guide_capture.h>

// Exercise the real runtime startup/delivery path. Its dialog stays private.
namespace rex::kernel::xam {
void StartExitOverlay(rex::ui::ImGuiDrawer*,rex::ui::WindowedAppContext*);
void StopExitOverlay();
}

using namespace rex::ui;
using namespace rex::input;
using rex::X_STATUS;
using rex::X_RESULT;
class Context : public WindowedAppContext {
  void NotifyUILoopOfPendingFunctions() override {}
  void PlatformQuitFromUIThread() override {}
};
class TestSurface : public Surface {
 public:
  TypeIndex GetType() const override { return kTypeIndex_CAMetalLayer; }
  bool GetSizeImpl(uint32_t& w,uint32_t& h) const override {w=640;h=360;return true;}
};
class TestWindow : public Window {
 public:
  explicit TestWindow(Context& c) : Window(c,"no native window",640,360) {}
  ~TestWindow() override {EnterDestructor();}
  bool pending=false;
  unsigned requests=0;
  void Paint() {pending=false;OnPaint();}
 private:
  bool OpenImpl() override {
    WindowDestructionReceiver receiver(this);OnActualSizeUpdate(640,360,receiver);return true;
  }
  void RequestCloseImpl() override {}
  std::unique_ptr<Surface> CreateSurfaceImpl(Surface::TypeFlags) override {
    return std::make_unique<TestSurface>();
  }
  void RequestPaintImpl() override {pending=true;++requests;}
};
class Texture : public ImmediateTexture {
 public: Texture(uint32_t w,uint32_t h):ImmediateTexture(w,h){}
};
class Drawer : public ImmediateDrawer {
 public:
  std::unique_ptr<ImmediateTexture> CreateTexture(uint32_t w,uint32_t h,
      ImmediateTextureFilter,bool,const uint8_t*) override {return std::make_unique<Texture>(w,h);}
  void BeginDrawBatch(const ImmediateDrawBatch&) override {}
  void Draw(const ImmediateDraw&) override {}
  void EndDrawBatch() override {}
};
class TestPresenter : public Presenter {
 public:
  TestPresenter() : Presenter(nullptr) {InitializeCommonSurfaceIndependent();}
  Surface::TypeFlags GetSupportedSurfaceTypes() const override {return Surface::kTypeFlag_CAMetalLayer;}
  bool CaptureGuestOutput(RawImage&) override {return false;}
  unsigned paints=0;
 private:
  SurfacePaintConnectResult ConnectOrReconnectPaintingToSurfaceFromUIThread(
      Surface&,uint32_t,uint32_t,bool,bool& vsync) override {vsync=true;return SurfacePaintConnectResult::kSuccess;}
  void DisconnectPaintingFromSurfaceFromUIThreadImpl() override {}
  bool RefreshGuestOutputImpl(uint32_t,uint32_t,uint32_t,
      std::function<bool(GuestOutputRefreshContext&)>,bool&) override {return true;}
  PaintResult PaintAndPresentImpl(bool draw_ui) override {
    AppUIDrawContext context(640,360);if(draw_ui)ExecuteUIDrawersFromUIThread(context);
    ++paints;return PaintResult::kPresented;
  }
};
class OrdinaryDialog : public ImGuiDialog {
 public: explicit OrdinaryDialog(ImGuiDrawer* d) : ImGuiDialog(d) {}
};
class Pad : public rex::input::InputDriver {
 public:
  Pad() : InputDriver(nullptr,0) {}
  uint16_t buttons=0;
  X_STATUS Setup() override {return X_STATUS_SUCCESS;}
  void EnumerateDevices(std::vector<rex::input::DeviceInfo>& out) override {
    rex::input::DeviceInfo info;info.id=rex::input::DeviceId(1);out.push_back(info);
  }
  X_RESULT GetDeviceState(rex::input::DeviceId,X_INPUT_STATE* out) override {
    *out={};out->gamepad.buttons=buttons;return X_ERROR_SUCCESS;
  }
  X_RESULT GetDeviceCapabilities(rex::input::DeviceId,uint32_t,X_INPUT_CAPABILITIES*) override {return X_ERROR_DEVICE_NOT_CONNECTED;}
  X_RESULT SetDeviceVibration(rex::input::DeviceId,X_INPUT_VIBRATION*) override {return X_ERROR_DEVICE_NOT_CONNECTED;}
  X_RESULT GetDeviceKeystroke(rex::input::DeviceId,uint32_t,X_INPUT_KEYSTROKE*) override {return X_ERROR_DEVICE_NOT_CONNECTED;}
};
int main(int argc,char** argv) {
  const bool confirm_exit = argc == 2 && std::string_view(argv[1]) == "--confirm-exit";
  // The old runtime has no flag and still executes the same defective repaint
  // chain, allowing this test to fail on the original behavior.
  rex::cvar::SetFlagByName("macos_idle_toast_sleep","true");
  rex::cvar::SetFlagByName("macos_idle_exit_overlay_sleep","true");
  Context context; TestWindow window(context); window.Open(); TestPresenter presenter;
  window.SetPresenter(&presenter);
  Drawer drawing; ImGuiDrawer imgui(&window,0);imgui.SetPresenterAndImmediateDrawer(&presenter,&drawing);
  auto toast = std::make_shared<AchievementToastDialog>(&imgui,&drawing,nullptr);
  window.Paint();
  if (window.pending) {
    std::fprintf(stderr,"FAIL: empty toast schedules another host present (paints=%u requests=%u)\n",
                 presenter.paints,window.requests);return 1;
  }
  std::puts("PASS: empty notification stops the real repaint chain");
  {
    OrdinaryDialog ordinary(&imgui); window.Paint();
    if (!window.pending) {std::puts("FAIL: ordinary dialog lost continuous repaint");return 1;}
  }
  window.Paint();
  if (window.pending) {std::puts("FAIL: closing ordinary dialog leaves idle repaint");return 1;}
  rex::system::AchievementEvent event{};event.achievement.label="Fixture achievement";
  bool posted = false;
  const unsigned before = window.requests;
  std::thread producer([&] {posted=DeferAchievementNotification(context,toast,event);});
  producer.join();
  if (!posted || window.requests != before) {std::puts("FAIL: guest delivery touched UI");return 1;}
  context.ExecutePendingFunctionsFromUIThread();
  if (!window.pending) {std::puts("FAIL: queued notification didn't wake idle UI");return 1;}
  window.Paint();
  if (!window.pending) {std::puts("FAIL: queued toast doesn't animate");return 1;}
  std::this_thread::sleep_for(std::chrono::milliseconds(4600));window.Paint();
  if (window.pending) {std::puts("FAIL: expired toast keeps repainting");return 1;}
  std::puts("PASS: ordinary overlay and toast animation retain repaint; expiration returns to idle");
  rex::cvar::SetFlagByName("macos_idle_toast_sleep","false");window.Paint();
  if (!window.pending) {std::puts("FAIL: default-off behavior changed");return 1;}
  rex::cvar::SetFlagByName("macos_idle_toast_sleep","true");window.Paint();
  if (window.pending) {std::puts("FAIL: enabled idle policy didn't stop repaint");return 1;}
  std::puts("PASS: default-off behavior remains continuous; opt-in stops idle repaint");
  // A notification queued just before owner teardown must not revive or touch
  // a dead dialog/drawer. Exercise the actual runtime dispatch helper.
  DeferAchievementNotification(context,toast,event);
  toast.reset();
  const unsigned after_destroy = window.requests;
  context.ExecutePendingFunctionsFromUIThread();
  if (window.requests != after_destroy) {std::puts("FAIL: destroyed notification woke UI");return 1;}
  std::puts("PASS: guest delivery wakes only on UI thread; expired weak owner cancels deferred delivery");
  rex::input::InputSystem input(nullptr);
  auto driver=std::make_unique<Pad>();auto* pad=driver.get();input.AddDriver(std::move(driver));
  input.SetDeviceAssignment(std::make_unique<rex::input::SlotAssignment>());
  auto poll=[&](uint16_t buttons) {
    pad->buttons=buttons;X_INPUT_STATE state{};X_RESULT result=0;
    std::thread guest([&] {result=input.GetState(0,&state);});guest.join();
    if(result!=X_ERROR_SUCCESS) {std::puts("FAIL: fixture input poll");std::exit(1);}
  };
  rex::kernel::xam::StartExitOverlay(&imgui,&context);window.Paint();
  if(window.pending) {std::puts("FAIL: started exit overlay isn't idle");return 1;}
  poll(0);const unsigned before_chord=window.requests;poll(0x2010);
  if(window.requests!=before_chord) {std::puts("FAIL: input thread painted directly");return 1;}
  context.ExecutePendingFunctionsFromUIThread();
  if(!window.pending) {std::puts("FAIL: exit shortcut failed to wake idle UI");return 1;}
  window.Paint();
  if(!window.pending || !rex::input::GuideCaptureActive()) {std::puts("FAIL: open exit dialog didn't redraw/capture pad");return 1;}
  if(confirm_exit) {
    std::puts("Expect clean fixture termination from real exit-confirm A path");std::fflush(stdout);
    poll(0);poll(0x1000);window.Paint();
    std::puts("FAIL: exit-confirm A didn't terminate fixture");return 1;
  }
  poll(0);poll(0x2000);window.Paint();
  if(window.pending || rex::input::GuideCaptureActive()) {std::puts("FAIL: cancel didn't release input and return to idle");return 1;}
  std::puts("PASS: real input shortcut wakes exit UI, open dialog captures/redraws, cancel releases input");
  poll(0);poll(0x2010);rex::kernel::xam::StopExitOverlay();
  const unsigned after_exit_destroy=window.requests;context.ExecutePendingFunctionsFromUIThread();
  if(window.requests!=after_exit_destroy) {std::puts("FAIL: queued shortcut wakes destroyed exit overlay");return 1;}
  std::puts("PASS: exit overlay teardown cancels queued wakes");
  imgui.SetPresenterAndImmediateDrawer(nullptr,nullptr);window.SetPresenter(nullptr);
}
