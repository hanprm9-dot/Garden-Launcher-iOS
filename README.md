<div align="center">
  <img src="assets/Garden-Launcher-Icon.png" alt="Garden Launcher" width="108" />
  <h1>Garden Launcher</h1>
  <p><b>Launcher &amp; Mod Manager cho Stardew Valley PC 1.6.15 trên iOS &amp; iPadOS</b></p>

  <p>
    <a href="https://github.com/hanprm9-dot/Garden-Launcher-iOS/releases/tag/v1.1.3"><img src="https://img.shields.io/badge/Version-v1.1.3-2ea44f?style=flat-square" alt="Version v1.1.3" /></a>
    <a href="https://discord.gg/tuTKv9xQ2Z"><img src="https://img.shields.io/badge/Discord-Vườn%20Bách%20Thú-5865F2?style=flat-square&logo=discord&logoColor=white" alt="Discord Server" /></a>
    <img src="https://img.shields.io/badge/iOS%20%2F%20iPadOS-14%20–%2027+-007aff?style=flat-square&logo=apple&logoColor=white" alt="iOS & iPadOS 14-27+" />
    <img src="https://img.shields.io/badge/SMAPI-4.5.2-6f42c1?style=flat-square" alt="SMAPI 4.5.2" />
    <img src="https://img.shields.io/badge/JIT-Không%20cần%20(0%25)-f59e0b?style=flat-square" alt="0% JIT" />
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-64747b?style=flat-square" alt="MIT License" /></a>
  </p>
</div>

> [!NOTE]
> **Launcher sạch (0% tệp bản quyền):** Kho mã nguồn và các bản `.ipa` không chứa dữ liệu game của ConcernedApe. Bạn cần tự chuẩn bị bộ dữ liệu **Stardew Valley PC 1.6.15** của riêng mình.
> 💬 **Cộng đồng Discord Chính Thức:** Tham gia [**Vườn Bách Thú 🦖 | Garden Launcher**](https://discord.gg/tuTKv9xQ2Z) để giao lưu Co-op, tải Mod & Việt hóa 1.6, hỏi đáp **Haley AI 🌻** và nhận hỗ trợ trực tiếp!

---

## 📥 Tải xuống (`v1.1.3`)

| Thiết bị | Phiên bản IPA | Tải về |
| :--- | :--- | :---: |
| **iOS / iPadOS 14 – 18** | `Garden-Launcher-1.1.3-iOS14-18.ipa` | [**⬇️ Tải ngay**](https://github.com/hanprm9-dot/Garden-Launcher-iOS/releases/download/v1.1.3/Garden-Launcher-1.1.3-iOS14-18.ipa) |
| **iOS / iPadOS 26 – 27+** | `Garden-Launcher-1.1.3-iOS26-27.ipa` | [**⬇️ Tải ngay**](https://github.com/hanprm9-dot/Garden-Launcher-iOS/releases/download/v1.1.3/Garden-Launcher-1.1.3-iOS26-27.ipa) |

---

## ✨ Điểm mới nổi bật trong `v1.1.3`, `v1.1.2` & `v1.1.1`

- **🛠️ Bản Vá Khẩn Cấp `v1.1.3` (`#GL-HCV3WF` & `#GL-MBJTCP`) — Sửa Dứt Điểm Lỗi Âm Thanh `UI Info Suite 2` / `SVE`, Lỗi Thứ Tự `GameLaunched` Của `Content Patcher`/`FTM` & Chẩn Đoán Mod Chính Xác:**
  - **Sửa triệt để `FieldAccessException` trong `SoundBank.AddCue` & `MethodAccessException` tiềm ẩn trong `CopyFromTexture` (`#GL-HCV3WF`):** Mở quyền truy cập nội bộ (`internal`) và gỡ cờ `initonly` cho các trường `XactSound._volume`, `_cueVolume`, `_useReverb`, `_categoryID` (khôi phục 100% âm thanh tùy chỉnh `Data/AudioChanges` của **Stardew Valley Expanded** và sự kiện `GameLaunched` của **UI Info Suite 2 v2.3.7**); đồng thời mở quyền nội bộ `Texture.DeleteGLTexture` để đổi kích thước texture HD trong `Texture2D.CopyFromTexture` an toàn tuyệt đối và bổ sung bộ kiểm định tự động **0 lỗi truy cập private IL** vào quy trình build.
  - **Sửa lỗi đệ quy `CFRunLoop` lúc khởi động làm đảo thứ tự `GameLoop.GameLaunched` (`#GL-HCV3WF`):** Ngừng bơm `CFRunLoopRunInMode(kCFRunLoopDefaultMode)` trong `sdv_boot_on_log` ngay khi `CADisplayLink` đã được đăng ký (vẫn flush thanh tiến độ mượt bằng `[CATransaction flush]`), chấm dứt hoàn toàn việc `Game1.Tick()` chen ngang giữa `GameLaunched` khiến **Content Patcher** từ chối token của **Farm Type Manager (FTM)** và các mod nạp sau.
  - **Đại tu bộ Chẩn đoán Mod gọn gàng & chính xác (`#GL-MBJTCP`):** Gom toàn bộ danh sách mod C# có gọi `0Harmony` thành **1 thẻ thông tin màu xanh duy nhất** thay vì spam hàng chục cảnh báo màu cam gây hiểu nhầm *"không dùng được"*; chỉ đánh dấu mod C# đời cũ khi `MinimumApiVersion < 3.0.0` (không còn báo nhầm các mod 1.6 như *Polyamory Sweet 1.6.1*, *Content Patcher Animations 1.2.4*, *Producer Framework Mod 1.9.8*); loại bỏ cảnh báo giả xung đột `drawWater` giữa mod thường và shader, đồng thời hiển thị đủ dòng ngoại lệ khi mod báo lỗi trong `SMAPI-latest.txt`.

- **⚡ Siêu Mượt `v1.1.2` — Mở Khóa 60/120 FPS Menu, Kéo-Thả Balô & Di Chuyển Mobile Không Khựng + 5 Cải Tiến Từ `@Mudkip267`:**
  - **Mở khóa 60 FPS mặc định cho Menu trong game & Tùy chọn `60 / 30 FPS`:** Gỡ giới hạn khóa cứng `30 FPS` mặc định khi mở Balô, Rương, Cửa hàng và thêm nút chuyển trực tiếp **`60 FPS (Mượt)` / `30 FPS (Tiết kiệm)`** trong **Mod Garden → FPS, Thời tiết & Pin** (không cần khởi động lại game).
  - **Menu Mod Garden 60 / 120 FPS (ProMotion) & Công tắc nền Cực Quang (Aurora):** Tự động tạm dừng `CADisplayLink` của game nền khi mở toàn màn hình Mod Garden ở chế độ Chơi đơn (trong Co-op Multiplayer vẫn giữ nhịp mạng và tự `SuppressDraw()` giảm tải GPU, tự động `ResetElapsedTime()` khi đóng) để thao tác cuộn/bấm trong Mod Garden đạt trọn vẹn **60 / 120 Hz**; bổ sung công tắc bật/tắt hiệu ứng nền động **Aurora** tức thì.
  - **Kéo-thả vật phẩm Balô & Rương 0-Flush:** Loại bỏ 3 lần ngắt `SpriteBatch.End()/Begin()` mỗi khung hình khi kéo vật phẩm, hạ ngưỡng kéo Balô nhạy hơn (`14px`, giữ `24px` cho Rương để cuộn mượt), thêm bộ đệm hover & chuỗi tooltip không cấp phát rác GC.
  - **Di chuyển Mobile 60Hz mượt tuyệt đối:** Vá khớp nhịp VSync **2.0 ms** trong `MonoGame.Framework.dll` (`Game.Tick()`) để triệt tiêu vòng lặp `Thread.Sleep(1)` gây trượt nhịp khung hình và nhảy `2× DoUpdate` trên iOS; nâng cấp **Làm mượt đường đi A\* (Lookahead Path Smoothing)** rút gọn điểm thẳng hàng & bo góc an toàn, bộ lọc **8 hướng có độ trễ chống rung (`Schmitt-trigger`)** cho joystick ảo và cache bố cục HUD (`ComputeLayout`) theo `Revision`.
  - **5 cải tiến ổn định, Font Việt hóa, Chân dung & Crash Log (đóng góp bởi [`@Mudkip267` — Nguyễn Ngọc Nguyên](https://github.com/Mudkip267/Garden-Launcher-iOS)):** Gỡ bỏ 2 lệnh `GC.WaitForPendingFinalizers()` chặn luồng + dọn trạng thái khi thoát về màn hình chính (`ReturnedToTitle`); hỗ trợ tệp font `.fnt` trong `Content/`, bảo vệ font Việt hóa (`smallFont`, `dialogueFont`, `minhhien`, `spritefont`) & thêm `@autoreleasepool` / kiểm tra `"Include"` khi đồng bộ locale; làm mới chân dung NPC khi chuyển map (`OnWarped`) và miễn trừ các gói CP chân dung/Việt hóa/font/theo mùa khỏi bộ dọn RAM; bổ sung bộ đệm vòng **16 dòng SMAPI cuối** an toàn tín hiệu trong Crash Log (`Embedded.m`); và chốt `ExternalInputBridge.PollFrame()` đúng **1 lần/tick** kèm tối ưu chế độ cảm ứng thuần.

- **🛠️ Bản Vá Khẩn Cấp `v1.1.1` (`#GL-V53YS2`) — Sửa Dứt Điểm Lỗi Texture Nhà Nông Trại (`Buildings/houses`) & Kích Hoạt Đầy Đủ Cold-Boot Stamp Cache:**
  - Gỡ bỏ nhánh `GL.BlitFramebuffer` trong `Texture2D.CopyFromTexture` (vốn bị khung cắt `GL_SCISSOR_TEST` còn lưu lại từ màn hình `LoadGameMenu` cắt trắng pixel khi Content Patcher cập nhật `Buildings/houses`, làm nhà bị giữ nguyên ảnh gốc vanilla và lộ phần mái nhà tầng 2 dưới bậc thềm), khôi phục cơ chế `GetData/SetData` miễn nhiễm Scissor & ColorMask kết hợp `try/finally` bảo toàn FBO.
  - Sửa lỗi `syncBundledSmapi` báo `dll-hash-mismatch` mỗi lần mở game khi `StardewModdingAPI.dll` đã được `RuntimeSmapiPatcher` vá tại chỗ, giúp bộ nhớ đệm `.garden/patch_stamps` bỏ qua phân tích `Mono.Cecil` thực sự từ lần mở thứ 2 trở đi.

- **🚀 Siêu Cập Nhật `v1.1.0` — Tối Ưu Cực Đại `0% JIT` / RAM / Tốc Độ Mở Game, Giảm Gần 6 MB IPA (`25.1 MB`) & 6 Tính Năng Mod Garden Mới:**
  - **Khởi động nhanh & Siêu nhẹ RAM (`v7` Engine Patcher):** Bộ nhớ đệm dấu vân tay vá IL (`.garden/patch_stamps`) rút ngắn **2–4 giây** thời gian mở game từ lần thứ 2; sao chép `Texture2D.CopyFromTexture` bằng phần cứng GPU `GL.BlitFramebuffer` (**0 byte RAM trung gian**); tái sử dụng bộ đệm tĩnh `PathFinder` A\* + Delegate đóng cho `PadBridge` giúp **0 cấp phát rác GC mỗi khung hình 60Hz**; nâng cấp trình biên dịch Shader GLSL ES (`#version 420..460`, `texture2DLodEXT`, `[ThreadStatic]` an toàn đa luồng) & phát âm thanh Mod tùy chỉnh (`CueDefinition.SetSound` + `SoundBank.AddCue`); khử trùng lặp tài nguyên giúp giảm dung lượng IPA xuống chỉ còn **`25.13 MB`**.
  - **6 Công cụ Mod Garden thế hệ mới:** **Hồ sơ Bộ Mod & Safe Mode** (lưu/chuyển nhanh các bộ Mod hoặc tắt tạm Mod ngoài 1 chạm không mất file); **Trình chỉnh sửa trực quan `config.json` ngay trong Launcher** (*Offline GMCM* trước khi vào game) kèm **thanh tìm kiếm & bộ lọc Mod**; **Sửa lệch chữ Hoa/Thường APFS** tự động cho Mod PC & `Content/`; **Tự động nhận diện & gắn phím tắt Mod** đang bật (`CJB Cheats/Spawner`, `Lookup Anything`, `UI Info Suite 2`, `NPC Map`, `Tractor`, `Automate`, `TimeSpeed` & `config.json`); trình quản lý **QuickSave & 20 ô lưu nhanh (`SaveSlots`)**; và **Mã đồng bộ `#COOP-XXXXXX`** kiểm tra khớp 100% Mod khi chơi chung.
  - **Hoàn thiện Gameplay `1.6.15` & An toàn hệ thống iOS:** Cửa hàng Mobile hỗ trợ đầy đủ **Đá Quý Qi (`Qi Gems`), Hạt Óc Chó Vàng (`Golden Walnuts`), bội số gói hàng & hệ số giảm giá**; khóa an toàn chống rơi/mất đồ tại **Lò Rèn Đảo Gừng (`ForgeMenu`)**, **Máy May (`TailoringMenu`)** & **Gói Bundle Nhà Văn Hóa (`JunimoNoteMenu`)**; hiển thị **HUD Trứng Calico** ở Hầm mỏ Lễ hội Sa mạc; tự phục hồi âm thanh OpenAL & mô-tơ rung `CoreHaptics` sau cuộc gọi/khóa màn hình; bảo vệ **22 giây ghi Save ngầm** khi vuốt ra màn hình chính và loại trừ `GardenHistory` khỏi sao lưu iCloud.

- **🌌 Giao Diện Cực Quang Toàn Menu Mod Garden (`SDVAuroraCanvasView`) & Sửa Dứt Điểm Chạm Đi Xe Mỏ (`v1.0.8`)** — Phủ lớp nền **Aurora sống động toàn bộ 9 tab của Mod Garden** (4 dải cực quang *Ngọc Lục Bảo · Blurple · Thạch Anh Tím · Xanh Băng* kèm sóng lụa chéo chạy GPU mượt mà xuyên qua kính mờ Sidebar, Thanh điều hướng và hệ thống thẻ nổi bán trong suốt viền sáng `sdvDynamicAuroraCardBg`, tự động đổi bảng màu theo **Light / Dark Mode** và tự nghỉ khi bật *Chế độ Nguồn điện thấp* hoặc *Giảm chuyển động*); sửa triệt để lỗi chế độ **Chạm đi A\* (`Tap-to-Move`) không nhận diện Xe mỏ (`Minecart`)** tại *Trạm Xe Buýt, Lò Rèn Thị Trấn, Mỏ Đá & Cửa Hầm Mỏ* (bắt đủ tile `Buildings` `958 / 1080 / 1081` không có thuộc tính `Action`, hỗ trợ chạm phần miệng/than tầng `Front` `tile.Y - 1`, tự chọn nửa xe thông thoáng cho xe mỏ 2 ô nằm sát hốc đá và mở tiếp cận chéo `HasWalkableCardinalNeighbor`), đồng thời bổ sung Chạm đi tự động cho **Thảm Vẹt Đảo Gừng (`Parrot Express`)**, **Máy bán vé xe buýt**, **Cuộn giấy Bundle Nhà Văn Hóa**, **Xe than trong mỏ** và **Tượng Calico `1.6`**.

- **💬 Cộng Đồng Server Discord Chính Thức & Thẻ Tương Tác Aurora (`v1.0.7`)** — Tích hợp liên kết mời vĩnh viễn [**Vườn Bách Thú 🦖 · Garden Launcher**](https://discord.gg/tuTKv9xQ2Z) xuyên suốt ứng dụng: nút nhanh **`Discord`** phát sáng trên thanh điều hướng trên cùng (hiển thị ở cả 9 tab) và thẻ **Hero Aurora** tại tab *Thiết lập / Cài Mod*, *Co-op LAN* & *Credit* với chuyển động cực quang 4 dải màu, linh vật **Discord Clyde** vector nổi bồng bềnh kèm 4 sao lấp lánh, tia sáng holographic lướt chéo, chấm radar **`● ONLINE`** cập nhật số người trực tuyến theo thời gian thực, hiệu ứng xoay 360° & bung pháo sáng đa sắc khi chạm, nút hỗ trợ nhanh ở tab *Báo lỗi* và cơ chế đồng bộ `discord_url` từ xa qua `version.json`.

- **🎯 Đại Tu Gameplay Stardew `1.6.15`, `SInputState` `0% JIT` & An Toàn Lưu Nhanh (`v1.0.6`)** — Sửa ná cao su (**Slingshot**) giữ tọa độ tâm ngắm khi nhả bắn, đảo gương tâm kéo ngược chuẩn hướng đạn và đi bộ tự nhiên ở chế độ *Chạm đi A\**; sửa đặt đồ 1 chạm vào quầy trưng bày Hội chợ (**Fair Grange Display**), phản hồi `0ms` trò đập búa (**StrengthGame**) và câu cá Hội chợ (**FishingGame**); sửa tháo mồi/phao cần Iridium nâng cấp 2 khe, chống mất vật phẩm vĩnh viễn khi balô đầy `36/36`, cho phép đổi đồ **Desert Trader** khi tiêu vừa khít 1 ô; cưỡi ngựa lọt cổng rào mở 1 ô chuẩn `1.6` & không nhảy khỏi ngựa khi mở rương; bơm trực tiếp tay cầm vật lý (`GamePad.ExternalGetStateHook`) vào `SInputState.TrueUpdate()` kích hoạt **100% sự kiện phím bấm Mod SMAPI trên `0% JIT`**; kẹp biên chống trôi camera menu xây chuồng Robin / Bảo tàng; bảo toàn bộ đếm giờ máy móc (`Keg`/`Cask`/`Jar` không nhảy gấp đôi) & chống kẹt đá/dung nham khi **QuickLoad** ở Hầm mỏ/Núi lửa; đồng bộ đầy đủ tài nguyên màn hình khởi động lên mã nguồn.

- **🛡️ Tổng Rà Soát & Vá Triệt Để 8 Nhóm Lỗi Hệ Thống (`v1.0.5`)** — Tự động phục hồi lịch sử cài Mod dở dang (`History.m`) chống kẹt cứng vĩnh viễn giữa *Cài Mod* và *Hoàn tác*; hoàn thiện **OTA Hot-Patch** đồng bộ đủ cặp `SDViOSTouchControls.dll` + `SDViOSTouchControlsMod.dll` (`EntryDll`) không bị ghi đè khi *Kiểm tra lại dữ liệu*; sửa treo thông báo *Kiểm tra cập nhật* thủ công + chống khóa nhầm 30 phút khi mất mạng lúc mở app & tránh chạm trần `60 req/giờ` CGNAT; đưa **vật lý phao câu cá Mobile (`BobberBar`) + chống nhả câu sớm + cứu kẹt `isReeling`** chạy trực tiếp trên nền `0% JIT` (Zero-Harmony); kẹp biên an toàn số tab `GameMenu` (`LB`/`RB`), tự nhả khóa bàn phím ngoài khi đóng Mod Garden, bỏ quét quyền thừa lúc khởi động SMAPI và nâng giới hạn gửi `ErrorLogs.zip` lên `7.5–8.5 MB`.

- **🛠️ Sửa Khẩn Cấp Lỗi Quyền Truy Cập `ModGardenBatch` (`#GL-WY7FCB`) & Tối Ưu Kiểm Tra Cập Nhật Mạng VN (`v1.0.4`)** — Sửa dứt điểm lỗi đặt nhầm `chmod 0644` lên thư mục làm mất quyền duyệt `0755` (`"ModGardenBatch" couldn't be removed because you don't have permission to access it`) khi cài/xóa Mod & File Save; bổ sung bộ tự động mở khóa & dọn sạch mọi thư mục kẹt quyền ngay khi mở ứng dụng, đồng thời chuyển kênh kiểm tra cập nhật chính sang `api.github.com` chống chặn mạng tại Việt Nam.

- **⚡ Cập Nhật Nhanh Trực Tiếp Trong Ứng Dụng (OTA Hot-Patch — Không Cần Ký Lại IPA)** — Tích hợp bộ nạp & xác thực gói cập nhật nhanh `SHA-256` ngay từ lúc khởi động (`0% JIT`): từ bản `v1.0.3` trở đi, các bản cập nhật sửa lỗi C# / điều khiển / tay cầm / SMAPI tiếp theo có thể cài đặt chỉ bằng **1 chạm ngay trong Mod Garden** (`~100–250 KB`) rồi mở lại game — **không cần tải lại tệp `.ipa` 32 MB và không cần ký lại chứng chỉ** trên KSign / ESign / SideStore, kèm van an toàn tự khôi phục gốc IPA nếu lỗi khởi động và nút **Về gốc IPA** trong tab Credit.
- **Logo Slime Khung Đá Rêu Pixel 16-bit & Mở Quyền Truy Cập `StardewValley/Content` trong Tệp** — Thay bộ biểu tượng ứng dụng Slime xanh lá trong khung đá rêu cổ điển; khôi phục thư mục hiển thị **`Tệp → Trên iPhone → Garden Launcher → StardewValley/Content`** (tự chuyển `.game/` cũ sang `StardewValley/` tức thì) và bổ sung thẻ **Nạp lại Game / Content (`.ZIP/.RAR/.7Z` hoặc Thư mục)** ngay trong tab **Cài Mod** kèm tự động chuyển `libarchive` cho gói nén Deflate64 Windows (`#GL-FKRBMM`).
- **Đại Tu Toàn Diện Tay Cầm Console & Rung `CoreHaptics`** — Đồng bộ trực tiếp `SInputState` + `SnappyMenus` cùng khung hình trên nền `0% JIT`: tự bám ô đầu tiên ngay khi mở Menu, chuyển tab & nhảy qua lại giữa các khung **Balô ↔ Rương ↔ Trang bị/Thùng rác ↔ Hàng hóa Shop** bằng **`LB` / `RB` / `LT` / `RT`**, hỗ trợ đủ **Thay đồ (Swap)**, **Vứt đồ ra ngoài (Drop)** (sửa kẹp biên màn hình iPhone với vùng thả `-99998`), **Giữ `A` + Di chuyển + Nhả `A` để Kéo-Thả (Drag & Drop)** song song với nhấn `A` 2 lần kiểu Console, lái con trỏ tự do bằng **R-Stick** trong mọi Menu (kể cả thanh trượt GMCM & icon **UI Info Suite 2 v2.3.7**) và rung phản hồi **`CoreHaptics`** 2 mô-tơ (tích hợp cùng đóng góp của `@Mudkip267`).
- **Chế Độ Tay Cầm Thuần (`Pure Gamepad Mode`) kèm Khởi Động Lại 1 Chạm** — Công tắc mới ngay đầu tab **Điều khiển**: tắt hoàn toàn HUD ảo & lớp chặn cảm ứng ngay từ lúc khởi động để chơi thuần như máy Console cầm tay (Backbone / Razer Kishi / Xbox / DualSense / Switch Pro) mà **không xung đột** với các bản vá tay cầm hay bàn phím đặt tên iOS.
- **Sửa Dứt Điểm Lỗi Không Di Chuyển Được Trong Event & Lễ Hội** — Mở khóa hoàn toàn di chuyển, tìm đường A* và tương tác nói chuyện / quầy hàng / câu cá trong mọi sự kiện & lễ hội có điều khiển nhân vật (`Event.playerControlSequence`, vd: Lễ hội Trứng, Vũ điệu Hoa, Hội chợ, Đêm Linh Hồn...), đồng thời hiển thị nút **SKIP** chuẩn sprite gốc cho các đoạn cắt cảnh thường (tự nhận giao diện Cat Valley UI).
- **Đồng Bộ Chân Dung Anime Theo Mùa, Tương Thích `UI Info Suite 2` & Tối Ưu Hầm Mỏ** — Tự động tải lại chân dung NPC khi Content Patcher đổi mùa/trang phục (`AssetsInvalidated` không gây mất ảnh hội thoại), bổ sung `CueDefinition` trong `MonoGame.Framework.dll` cho **UI Info Suite 2 v2.3.7+**, dời số tầng Hầm mỏ / Hang Sọ / Núi lửa thoát khỏi góc bo tròn iPhone, và đưa bộ dọn RAM 2 mức (`85%` nhẹ / `91%` khẩn cấp) sang hàng đợi nền chống khựng (đóng góp bởi `@Mudkip267`).

---

## 🌟 Hệ thống tính năng cốt lõi

- **Màn hình Loading Pixel Art 16-bit chuẩn `0% → 100%` & Tự dọn Crash Marker** — Thanh tiến độ RPG có Junimo pixel nhảy theo mép thanh, 5 mốc giai đoạn (`.NET · SMAPI · Mods · Nội dung · Vào Game`), bảng RAM live và tự dọn `StardewModdingAPI.crash.marker` chống kẹt màn hình tải.
- **4 Chế Độ Cảm Ứng Mobile + Ngoại Vi Đầy Đủ** — *Vô hình*, *2 Nút Pixel*, *Chạm đi A\**, *Kết hợp* (tối ưu riêng cho iPad 4:3), kéo cuộn Shop 1:1 + thanh trượt `1..999`, bàn phím vật lý (`WASD`, `F1–F12`, phím tắt mod SMAPI), chuột/trackpad PC và tiết kiệm pin `60 / 45 / 30 FPS`.
- **Mod Garden 9 Tab & Kiểm Tra Cập Nhật Tự Động** — Chạm **3 ngón tay × 2** để mở Mod Garden ngay trong game: cài Mod & `.XNB`, **Console Log** thời gian thực, 20 mốc **Lưu nhanh**, **Báo lỗi Online** kèm ảnh/video & `ErrorLogs.zip`, chẩn đoán xung đột mod và tự kiểm tra phiên bản mới qua `version.json`.
- **Tương Thích Mod UI, Shader MGFX v8–v10, Tiếng Việt & Co-op LAN / IP** — Hỗ trợ `Texture2D.CopyFromTexture`, GLSL ES `highp` (`DynamicShader`, `DynamicReflections`, `SDV-Radiance`), tự phục hồi SMAPI iOS `4.5.2`, bảo vệ hòm thư `Data/mail` 1.6 và chơi chung qua Wi-Fi LAN / ZeroTier / Tailscale.

---

## 🚀 Cài đặt nhanh

1. **Cài IPA** bằng KSign / ESign / TrollStore / SideStore / Sideloadly *(cài đè cùng Bundle ID giữ nguyên Save & Mod)*.
2. **Nạp game PC `1.6.15`**: Nén thư mục game PC (`.ZIP`/`.RAR`/`.7Z`) → mở app → bấm **Nhập gói dữ liệu game** *(hoặc chép thẳng vào `Tệp → Trên iPhone → Garden Launcher → StardewValley`)* → chờ thông báo xanh thành công → bấm **Khởi động lại**.
3. **Cài Mod / Việt hóa / `.XNB`**: Chạm **3 ngón tay × 2** → tab **Cài Mod** → chọn 1 hoặc nhiều gói Mod/XNB cùng lúc → bấm **Cài tất cả** → bấm **Khởi động lại**.
4. **Dùng Tay cầm**: Cắm/kết nối tay cầm để game tự nhận ngay, hoặc vào **Mod Garden → Điều khiển → Chế độ Tay cầm thuần** rồi bấm **Khởi động lại ngay** nếu chỉ chơi bằng tay cầm.

<table>
  <tr>
    <td align="center" width="50%">
      <img src="assets/Huong-Dan-1-Setup-Launcher-Liquid3D.jpg" alt="Hướng dẫn Setup Garden Launcher (Phần 1/2)" /><br/>
      <sub><b>Phần 1 / 2 · Hướng dẫn Setup Garden Launcher</b></sub>
    </td>
    <td align="center" width="50%">
      <img src="assets/Huong-Dan-2-Cai-Mod-Viet-Hoa-Liquid3D.jpg" alt="Hướng dẫn Cài Mod &amp; Việt Hóa (Phần 2/2)" /><br/>
      <sub><b>Phần 2 / 2 · Hướng dẫn Cài Mod &amp; Việt Hóa</b></sub>
    </td>
  </tr>
</table>

---

<details>
<summary><b>🛠️ Build từ mã nguồn (Dành cho lập trình viên)</b></summary>

Yêu cầu: base IPA từ [SDViosport](https://github.com/DeadAKJ/SDViosport), `zig cc`, `ld64.lld`, `iPhoneOS.sdk`, `.NET 6.0+ SDK`, `zsign`, `Mono.Cecil.dll`, Python 3.10+.

```powershell
# 1. Build mod điều khiển C# SDVMobileControls
dotnet build ModGarden\SDVMobileControls\SDVMobileControls.csproj -c Release

# 2. Vá IL (MonoGame.Framework.dll, SDViOS.dll, SDViOSTouchControls.dll)
powershell -ExecutionPolicy Bypass -File scripts\patch_perf_v7.ps1

# 3. Đóng gói 2 bản IPA sạch (iOS / iPadOS 26–27+ & iOS / iPadOS 14–18)
python scripts\package_embedded.py base-sdvios.ipa build\SDVModGarden_ios26 zsign.exe dist\Garden-Launcher-1.1.3-iOS26-27.ipa "$WorkDir\v7-host.dll" "$WorkDir\v7-touch.dll" "$WorkDir\Lidgren.Network.dll" --launcher --min-ios=16.0
python scripts\package_embedded.py base-sdvios.ipa build\SDVModGarden_ios14 zsign.exe dist\Garden-Launcher-1.1.3-iOS14-18.ipa "$WorkDir\v7-host.dll" "$WorkDir\v7-touch.dll" "$WorkDir\Lidgren.Network.dll" --launcher --no-scene --min-ios=14.0
```

</details>

---

<p align="center">
  <b>Credits:</b>
  <a href="https://www.stardewvalley.net/">ConcernedApe</a> ·
  <a href="https://github.com/DeadAKJ/SDViosport">SDViosport</a> (MIT) ·
  <a href="https://smapi.io/">SMAPI</a> (LGPL-3.0) ·
  <a href="https://github.com/Mudkip267/Garden-Launcher-iOS">Mudkip267 (Nguyễn Ngọc Nguyên)</a> ·
  <a href="https://github.com/richgel999/miniz">miniz</a> (MIT)
</p>
