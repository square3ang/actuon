//! Interface text in English, Korean, Japanese and Simplified Chinese. The English text is the key.
//! A key with no row stops the build. BMS and beatoraja terms (gauge and lamp names, EX, BP, LN) stay as they are.
const std = @import("std");
const c = @import("c");

pub const Lang = enum { en, ko, ja, zh };

/// Each language's name in itself, in `Lang` order.
pub const names = [_][]const u8{ "English", "한국어", "日本語", "简体中文" };

pub var current: Lang = .en;

/// A code from config.json, which anyone can edit, so an unknown one is null.
pub fn fromCode(code: []const u8) ?Lang {
    return std.meta.stringToEnum(Lang, code);
}

/// The player's choice, or else the first OS language with a translation, or else English.
pub fn resolve(saved: []const u8) Lang {
    if (fromCode(saved)) |l| return l;
    var count: c_int = 0;
    const locales = c.SDL_GetPreferredLocales(&count) orelse return .en;
    defer c.SDL_free(@ptrCast(locales));
    for (locales[0..@intCast(count)]) |locale| {
        if (fromCode(std.mem.span(locale.*.language))) |l| return l;
    }
    return .en;
}

const Row = [std.enums.values(Lang).len][]const u8;

fn row(comptime en: []const u8) *const Row {
    comptime {
        @setEvalBranchQuota(2_000_000);
        for (&rows) |*r| {
            if (std.mem.eql(u8, r[0], en)) return r;
        }
        @compileError("no translation for: " ++ en);
    }
}

pub fn tr(comptime en: []const u8) []const u8 {
    return (comptime row(en))[@backingInt(current)];
}

pub fn bufPrint(buf: []u8, comptime en: []const u8, args: anytype) std.fmt.BufPrintError![]u8 {
    const r = comptime row(en);
    return switch (current) {
        inline else => |l| std.fmt.bufPrint(buf, r[@backingInt(l)], args),
    };
}

const rows = [_]Row{
    // Settings tabs.
    .{ "Library", "라이브러리", "ライブラリ", "曲库" },
    .{ "Tables", "난이도표", "難易度表", "难度表" },
    .{ "Audio", "오디오", "オーディオ", "音频" },
    .{ "Display", "화면", "画面", "显示" },
    .{ "Timing", "타이밍", "タイミング", "时机" },
    .{ "Scores", "점수", "スコア", "成绩" },
    .{ "Online", "온라인", "オンライン", "在线" },
    .{ "Controls", "조작", "操作", "操作" },
    .{ "Settings", "설정", "設定", "设置" },

    // Settings rows.
    .{ "Add folder", "폴더 추가", "フォルダを追加", "添加文件夹" },
    .{ "Remove all folders", "모든 폴더 제거", "全フォルダを削除", "移除所有文件夹" },
    .{ "Open data folder", "데이터 폴더 열기", "データフォルダを開く", "打开数据文件夹" },
    .{ "Settings, scores, replays and skins live here.", "설정, 점수, 리플레이, 스킨이 여기 있어요.", "設定、スコア、リプレイ、スキンはここにあります。", "设置、成绩、回放和皮肤都在这里。" },
    .{ "Add by address", "주소로 추가", "アドレスで追加", "通过地址添加" },
    .{ "Update all", "모두 업데이트", "すべて更新", "全部更新" },
    .{ "Master volume", "전체 볼륨", "マスター音量", "主音量" },
    .{ "Menu music", "메뉴 음악", "メニュー音楽", "菜单音乐" },
    .{ "Music set", "음악 세트", "音楽セット", "音乐组" },
    .{ "Sound set", "효과음 세트", "効果音セット", "音效组" },
    .{ "Menu sounds", "메뉴 효과음", "メニュー効果音", "菜单音效" },
    .{ "Sample rate", "샘플 레이트", "サンプルレート", "采样率" },
    .{ "Buffer size", "버퍼 크기", "バッファサイズ", "缓冲区大小" },
    .{ "Output device", "출력 장치", "出力デバイス", "输出设备" },
    .{ "Fullscreen", "전체 화면", "フルスクリーン", "全屏" },
    .{ "VSync", "VSync", "VSync", "VSync" },
    .{ "NVIDIA Reflex", "NVIDIA Reflex", "NVIDIA Reflex", "NVIDIA Reflex" },
    .{ "BGA movie upscaling (FSRCNNX)", "BGA 영상 업스케일 (FSRCNNX)", "BGA動画アップスケール (FSRCNNX)", "BGA 视频放大 (FSRCNNX)" },
    .{ "Skin", "스킨", "スキン", "皮肤" },
    .{ "Skins per screen", "화면별 스킨", "画面別スキン", "各画面皮肤" },
    .{ "Open skin folder", "스킨 폴더 열기", "スキンフォルダを開く", "打开皮肤文件夹" },
    .{ "Put each skin in its own folder here, then pick it under Skin.", "스킨마다 폴더째로 여기에 넣고 스킨에서 고르세요.", "スキンはフォルダごとここに入れ、スキンで選んでください。", "把每个皮肤按文件夹放进这里，然后在皮肤里选择。" },
    .{ "Language", "언어", "言語", "语言" },
    .{ "Green number", "그린 넘버", "緑数字", "绿色数字" },
    .{ "Lift", "리프트", "リフト", "LIFT" },
    .{ "Hidden", "히든", "HIDDEN", "HIDDEN" },
    .{ "Judge offset", "판정 오프셋", "判定オフセット", "判定偏移" },
    .{ "Visual offset", "화면 오프셋", "表示オフセット", "画面偏移" },
    .{ "Import beatoraja scores", "beatoraja 점수 가져오기", "beatorajaのスコアを取り込む", "导入 beatoraja 成绩" },
    .{ "Import LR2 scores", "LR2 점수 가져오기", "LR2のスコアを取り込む", "导入 LR2 成绩" },
    .{ "IR server", "IR 서버", "IRサーバー", "IR 服务器" },
    .{ "Create IR account", "IR 계정 만들기", "IRアカウント作成", "创建 IR 账号" },
    .{ "Sign in to IR", "IR 로그인", "IRにログイン", "登录 IR" },
    .{ "Change IR name", "IR 이름 변경", "IR名を変更", "修改 IR 名称" },
    .{ "Upload my scores to IR", "내 점수를 IR에 올리기", "スコアをIRにアップロード", "上传我的成绩到 IR" },
    .{ "Download my scores from IR", "IR에서 내 점수 받기", "IRからスコアをダウンロード", "从 IR 下载我的成绩" },
    .{ "Download URL", "다운로드 주소", "ダウンロードURL", "下载地址" },
    .{ "Game version", "게임 버전", "ゲームバージョン", "游戏版本" },
    .{ "Key polling", "키 폴링", "キーポーリング", "按键轮询" },
    .{ "4 key", "4키", "4鍵", "4键" },
    .{ "5 key", "5키", "5鍵", "5键" },
    .{ "6 key", "6키", "6鍵", "6键" },
    .{ "7 key", "7키", "7鍵", "7键" },
    .{ "10 key", "10키", "10鍵", "10键" },
    .{ "14 key", "14키", "14鍵", "14键" },
    .{ "9 key (PMS)", "9키 (PMS)", "9鍵 (PMS)", "9键 (PMS)" },
    .{ "beatoraja controls", "beatoraja 조작", "beatoraja操作", "beatoraja 操作" },
    .{ "Start, Select", "Start, Select", "Start, Select", "Start, Select" },

    // Settings help.
    .{ "Choose a folder. It is scanned for charts right away.", "폴더를 고르면 바로 채보를 찾아요.", "フォルダを選ぶとすぐに譜面を検索します。", "选择文件夹后立即扫描谱面。" },
    .{ "Forgets the folder list. Scores and chart files stay.", "폴더 목록만 지워요. 점수와 채보 파일은 그대로예요.", "フォルダ一覧を消します。スコアと譜面ファイルは残ります。", "清除文件夹列表。成绩和谱面文件会保留。" },
    .{ "Paste a table's web address with Ctrl+V. It loads right away.", "난이도표 주소를 Ctrl+V로 붙여 넣으면 바로 불러와요.", "難易度表のURLをCtrl+Vで貼り付けるとすぐ読み込みます。", "用 Ctrl+V 粘贴难度表网址，立即加载。" },
    .{ "Downloads every added table again. F8 in song select does the same.", "추가한 난이도표를 전부 다시 받아요. 곡 선택 화면에서 F8을 눌러도 돼요.", "追加した難易度表をすべて再取得します。選曲画面のF8と同じです。", "重新下载所有已添加的难度表。选曲界面按 F8 效果相同。" },
    .{ "Enter adds or removes the selected table. Removing keeps chart scores.", "Enter로 난이도표를 추가하거나 뺄 수 있어요. 빼도 점수는 남아요.", "Enterで選択中の難易度表を追加・削除します。削除してもスコアは残ります。", "按 Enter 添加或移除所选难度表。移除后成绩保留。" },
    .{ "Everything the game plays.", "게임에서 나는 모든 소리예요.", "ゲームのすべての音。", "游戏播放的所有声音。" },
    .{ "Enter or click lists the sound sets, or picks a folder holding them. Left/Right steps through them.", "Enter나 클릭으로 세트 목록을 열거나 폴더를 골라요. 좌우 키로 바꿀 수 있어요.", "Enterかクリックでセット一覧を開くかフォルダを選びます。左右キーで切り替えます。", "按 Enter 或点击列出音效组或选择文件夹。左右键切换。" },
    .{ "Enter or click lists select and decide music, or picks a folder holding it. Left/Right steps through them.", "Enter나 클릭으로 곡 선택·결정 음악 목록을 열거나 폴더를 골라요. 좌우 키로 바꿀 수 있어요.", "Enterかクリックで選曲・決定音楽の一覧を開くかフォルダを選びます。左右キーで切り替えます。", "按 Enter 或点击列出选曲与决定音乐或选择文件夹。左右键切换。" },
    .{ "The loop behind song select and settings: the skin's own music if it has any.", "곡 선택과 설정 화면에 깔리는 음악이에요. 스킨에 음악이 있으면 그걸 틀어요.", "選曲と設定で流れる音楽。スキンに音楽があればそれを使います。", "选曲和设置界面的背景音乐。皮肤自带音乐时优先使用。" },
    .{ "Cursor, confirm and result sounds.", "커서, 결정, 결과 화면 소리예요.", "カーソル、決定、リザルトの効果音。", "光标、确认和结算音效。" },
    .{ "Takes effect after a restart.", "다시 시작하면 적용돼요.", "再起動後に反映されます。", "重启后生效。" },
    .{ "Smaller is lower latency, too small crackles. Takes effect after a restart.", "작을수록 지연이 줄지만 너무 작으면 소리가 튀어요. 다시 시작하면 적용돼요.", "小さいほど低遅延ですが、小さすぎると音割れします。再起動後に反映されます。", "越小延迟越低，过小会爆音。重启后生效。" },
    .{ "Falls back to Default if it will not open. Applies when you leave settings.", "안 열리면 기본값을 써요. 설정에서 나갈 때 적용돼요.", "開けないときは既定を使います。設定を出ると反映されます。", "无法打开时使用默认值。离开设置时生效。" },
    .{ "The room did not take that", "방이 그 요청을 받지 않았어요", "ルームがその操作を受け付けませんでした", "房间未接受该操作" },
    .{ "Applies at once.", "바로 적용돼요.", "すぐに反映されます。", "立即生效。" },
    .{ "Window size", "창 크기", "ウィンドウサイズ", "窗口大小" },
    .{ "Applies at once. Fullscreen always fills the screen.", "바로 적용돼요. 전체 화면은 항상 화면을 채워요.", "すぐに反映されます。フルスクリーンは常に画面全体を使います。", "立即生效。全屏始终占满屏幕。" },
    .{ "Applies at once. Off lowers input latency and may tear.", "바로 적용돼요. 끄면 입력 지연은 줄지만 화면이 찢어질 수 있어요.", "すぐに反映されます。オフは入力遅延が減りますがティアリングが出ることがあります。", "立即生效。关闭可降低输入延迟，但可能出现画面撕裂。" },
    .{ "Cleaner, sharper movies when they are enlarged, for a little CPU and GPU time per movie frame. Applies to the next chart for deblocking.", "영상을 키울 때 더 또렷해지고 CPU와 GPU를 조금 더 써요. 디블로킹은 다음 채보부터 적용돼요.", "拡大した動画が鮮明になり、CPUとGPUを少し使います。デブロックは次の譜面から反映されます。", "放大视频更清晰，但会多占用一些 CPU 和 GPU。去块效果从下一张谱面生效。" },
    .{ "NVIDIA GPUs only. Boost holds GPU clocks high and uses more power.", "NVIDIA GPU에서만 돼요. Boost는 GPU 클럭을 높게 유지해서 전력을 더 써요.", "NVIDIA GPU専用。BoostはGPUクロックを高く保ち、電力を多く使います。", "仅限 NVIDIA GPU。Boost 会保持高频率并增加功耗。" },
    .{ "Enter picks a skin and its settings for each screen and key mode. The rest use the skin above.", "Enter로 화면과 키 모드마다 스킨과 설정을 골라요. 안 고른 곳은 위의 스킨을 써요.", "Enterで画面とキーモードごとにスキンと設定を選びます。残りは上のスキンを使います。", "按 Enter 为各画面和键位模式选择皮肤及设置。其余使用上方皮肤。" },
    .{ "Enter or click lists the skins folder, or picks a skin elsewhere. Left/Right steps through them.", "Enter나 클릭으로 스킨 폴더를 열거나 다른 곳에 있는 스킨을 골라요. 좌우 키로 바꿀 수 있어요.", "Enterかクリックでスキンフォルダの一覧を開くか他の場所から選びます。左右キーで切り替えます。", "按 Enter 或点击列出皮肤文件夹或从别处选择。左右键切换。" },
    .{ "The game's language. Applies at once.", "게임 언어예요. 바로 적용돼요.", "ゲームの言語。すぐに反映されます。", "游戏语言。立即生效。" },
    .{ "How long notes stay visible: higher is slower. Enter to type a number, 30 to 2000.", "노트가 보이는 시간이에요. 클수록 느려요. Enter를 누르고 30~2000 사이로 입력하세요.", "ノーツの表示時間。大きいほど遅くなります。Enterで30~2000の数字を入力します。", "音符可见时长，数值越大越慢。按 Enter 输入 30~2000 的数字。" },
    .{ "Raises the judge line. Home and End change it during play.", "판정선을 올려요. 플레이 중에는 Home, End로 바꿔요.", "判定ラインを上げます。プレイ中はHomeとEndで変更します。", "抬高判定线。游玩时用 Home 和 End 调整。" },
    .{ "Hides notes just above the judge line. Insert and Delete change it during play.", "판정선 바로 위의 노트를 가려요. 플레이 중에는 Insert, Delete로 바꿔요.", "判定ライン直上のノーツを隠します。プレイ中はInsertとDeleteで変更します。", "隐藏判定线上方的音符。游玩时用 Insert 和 Delete 调整。" },
    .{ "Positive forgives a player who hits late.", "늦게 치는 편이면 양수로 맞추세요.", "正の値は遅く叩くプレイヤーを補正します。", "正值用于补偿击打偏晚的玩家。" },
    .{ "Moves the notes without moving the judgement.", "판정은 그대로 두고 노트 위치만 옮겨요.", "判定はそのままでノーツの位置だけ動かします。", "只移动音符位置，不改变判定。" },
    .{ "Choose score.db. Note: judging differs from beatoraja, so lr2oraja scores are recommended.", "score.db를 고르세요. beatoraja와 판정이 달라서 lr2oraja 점수를 추천해요.", "score.dbを選びます。判定がbeatorajaと異なるためlr2orajaのスコアを推奨します。", "选择 score.db。判定与 beatoraja 不同，建议使用 lr2oraja 成绩。" },
    .{ "Choose the LR2 score database.", "LR2 점수 DB를 고르세요.", "LR2のスコアデータベースを選びます。", "选择 LR2 成绩数据库。" },
    .{ "Base address of the internet ranking server.", "인터넷 랭킹 서버 주소예요.", "インターネットランキングサーバーのベースURL。", "互联网排名服务器的基础地址。" },
    .{ "Makes an account on that server and signs in. Asks for a name, then a password.", "이 서버에 계정을 만들고 로그인해요. 이름과 비밀번호를 차례로 입력하세요.", "そのサーバーにアカウントを作りログインします。名前、パスワードの順に入力します。", "在该服务器创建账号并登录。依次输入名称和密码。" },
    .{ "Signs in to an account you already have on that server.", "이 서버에 있는 계정으로 로그인해요.", "そのサーバーの既存アカウントにログインします。", "登录你在该服务器上已有的账号。" },
    .{ "Changes the name shown in rankings. You then sign in with the new name. Scores stay.", "랭킹에 보이는 이름을 바꿔요. 다음부터 새 이름으로 로그인하세요. 점수는 그대로예요.", "ランキングの表示名を変えます。以後は新しい名前でログインします。スコアは残ります。", "修改排名中显示的名称。之后用新名称登录。成绩保留。" },
    .{ "Sends saved replays the server does not have yet. Scores without a replay, like imported ones, rank as unverified.", "서버에 없는 리플레이를 올려요. 가져온 점수처럼 리플레이가 없으면 미검증으로 올라가요.", "サーバーにないリプレイを送ります。取り込んだスコアなどリプレイなしは未検証になります。", "发送服务器上没有的回放。导入成绩等无回放的记录计为未验证。" },
    .{ "Merges your scores on the server into this library. Better local scores stay.", "서버에 있는 내 점수를 가져와 합쳐요. 로컬 점수가 더 좋으면 그대로 둬요.", "サーバーのスコアをこのライブラリに統合します。より良いローカルスコアは残ります。", "把服务器上的成绩合并到本曲库。更好的本地成绩保留。" },
    .{ "Where missing charts come from: an archive or a lookup service. {md5} becomes the chart's hash.", "없는 채보를 받을 곳이에요. 압축 파일이나 조회 서비스를 쓸 수 있고, {md5}는 채보 해시로 바뀌어요.", "足りない譜面の取得先。アーカイブか検索サービス。{md5}は譜面のハッシュになります。", "缺失谱面的来源：压缩包或查询服务。{md5} 会替换为谱面哈希。" },
    .{ "Checks GitHub at launch. Enter installs a new version for the next launch, or opens its page where the game cannot replace itself. Settings and scores stay.", "시작할 때 GitHub를 확인해요. Enter로 새 버전을 설치하거나 페이지를 열어요. 설정과 점수는 그대로예요.", "起動時にGitHubを確認します。Enterで新版を導入するかページを開きます。設定とスコアは残ります。", "启动时检查 GitHub。按 Enter 安装新版本或打开其页面。设置和成绩保留。" },
    .{ "Key checks per second during play. Higher takes more CPU. Event uses OS key events. macOS always does.", "플레이 중 1초에 키를 확인하는 횟수예요. 높을수록 CPU를 더 써요. 이벤트는 OS 키 이벤트를 쓰고, macOS는 항상 이 방식이에요.", "プレイ中の毎秒キー確認回数。高いほどCPUを使います。イベントはOSのキーイベント(macOSは常時)。", "游玩时每秒检查按键次数，越高越占 CPU。事件模式使用系统按键事件（macOS 始终如此）。" },
    .{ "Enter, then press each input in turn: 5 keys, scratch A, scratch B, per side.", "Enter를 누르고 사이드별로 5키, 스크래치 A, 스크래치 B를 차례로 누르세요.", "Enterの後、順に入力: サイドごとに5鍵、スクラッチA、スクラッチB。", "按 Enter 后依次输入：每侧 5 键、搓盘 A、搓盘 B。" },
    .{ "Enter, then press each input in turn: 7 keys, scratch A, scratch B, per side.", "Enter를 누르고 사이드별로 7키, 스크래치 A, 스크래치 B를 차례로 누르세요.", "Enterの後、順に入力: サイドごとに7鍵、スクラッチA、スクラッチB。", "按 Enter 后依次输入：每侧 7 键、搓盘 A、搓盘 B。" },
    .{ "Enter, then press each of the 4 keys in turn.", "Enter를 누르고 4개 키를 차례로 누르세요.", "Enterの後、4つのキーを順に押します。", "按 Enter 后依次按下 4 个键。" },
    .{ "Enter, then press each of the 6 keys in turn.", "Enter를 누르고 6개 키를 차례로 누르세요.", "Enterの後、6つのキーを順に押します。", "按 Enter 后依次按下 6 个键。" },
    .{ "Enter, then press each of the 9 buttons in turn.", "Enter를 누르고 9개 버튼을 차례로 누르세요.", "Enterの後、9つのボタンを順に押します。", "按 Enter 后依次按下 9 个按钮。" },
    .{ "Song select, result and play take the 7 key inputs and Start, Select as in beatoraja, on keyboard or controller.", "곡 선택, 결과, 플레이에서 7키와 Start, Select를 beatoraja처럼 써요. 키보드와 컨트롤러 둘 다 돼요.", "選曲、リザルト、プレイで7鍵とStart, Selectをbeatorajaと同様に使います。キーボードでもコントローラーでも。", "选曲、结算和游玩时按 beatoraja 方式使用 7 键及 Start、Select，键盘和手柄均可。" },
    .{ "Enter, then press Start, then Select. They open option panels in song select and change speed in play.", "Enter를 누르고 Start, Select 순서로 누르세요. 곡 선택에서는 옵션을 열고, 플레이 중에는 속도를 바꿔요.", "Enterの後、Start、Selectの順に押します。選曲ではオプション、プレイでは速度を操作します。", "按 Enter 后依次按 Start、Select。选曲时打开选项面板，游玩时调整速度。" },

    // Settings values and prompts.
    .{ "Event", "이벤트", "イベント", "事件" },
    .{ "Off", "끔", "オフ", "关" },
    .{ "On", "켬", "オン", "开" },
    .{ "Adaptive", "적응형", "適応", "自适应" },
    .{ "On + Boost", "켬 + Boost", "オン + Boost", "开 + Boost" },
    .{ "Default", "기본값", "既定", "默认" },
    .{ "Built-in", "내장", "内蔵", "内置" },
    .{ "From the skin", "스킨 기본값", "スキンのもの", "使用皮肤自带" },
    .{ "Pick a skin elsewhere...", "다른 곳의 스킨 고르기...", "他の場所のスキンを選ぶ...", "从别处选择皮肤..." },
    .{ "Pick a folder...", "폴더 고르기...", "フォルダを選ぶ...", "选择文件夹..." },
    .{ "{d} frames", "{d} 프레임", "{d} フレーム", "{d} 帧" },
    .{ "{d} configured", "{d}개 설정됨", "{d} 件設定済み", "已设置 {d} 个" },
    .{ "{d} added", "{d}개 추가됨", "{d} 件追加済み", "已添加 {d} 个" },
    .{ "Not set", "설정 안 됨", "未設定", "未设置" },
    .{ "Signed in", "로그인됨", "ログイン中", "已登录" },
    .{ "Not signed in", "로그인 안 됨", "未ログイン", "未登录" },
    .{ "New name: {s}_", "새 이름: {s}_", "新しい名前: {s}_", "新名称：{s}_" },
    .{ "Name: {s}_", "이름: {s}_", "名前: {s}_", "名称：{s}_" },
    .{ "Password: {s}_", "비밀번호: {s}_", "パスワード: {s}_", "密码：{s}_" },
    .{ "Remove", "제거", "削除", "移除" },
    .{ "Added", "추가됨", "追加済み", "已添加" },
    .{ "Add", "추가", "追加", "添加" },
    .{ "Score database", "점수 데이터베이스", "スコアデータベース", "成绩数据库" },
    .{ "All files", "모든 파일", "すべてのファイル", "所有文件" },
    .{ "Waiting for the file dialog...", "파일 선택 창을 기다리는 중...", "ファイルダイアログを待っています...", "正在等待文件对话框..." },
    .{ "Press the input for button {d} of {d}. Esc cancels.", "{d}/{d}번 버튼에 쓸 입력을 누르세요. Esc로 취소해요.", "ボタン {d}/{d} の入力を押してください。Esc: 取消。", "请按下按钮 {d}/{d} 的输入。Esc 取消。" },
    .{ "Enter or click to open this tab.", "Enter나 클릭으로 이 탭을 열어요.", "Enterかクリックでこのタブを開きます。", "按 Enter 或点击打开此标签页。" },
    .{ "Up/Down select    Left/Right change    Enter edit    Esc or right click back", "상하 선택    좌우 변경    Enter 편집    Esc·우클릭 뒤로", "上下 選択    左右 変更    Enter 編集    Esc・右クリック 戻る", "上下 选择    左右 更改    Enter 编辑    Esc/右键 返回" },
    .{ "Up/Down choose a tab    Enter open    Esc or right click leave", "상하 탭 선택    Enter 열기    Esc·우클릭 나가기", "上下 タブ選択    Enter 開く    Esc・右クリック 終了", "上下 选择标签页    Enter 打开    Esc/右键 离开" },

    // Settings messages.
    .{ "{s}", "{s}", "{s}", "{s}" },
    .{ "No file dialog available: type the path", "파일 선택 창을 열 수 없어요. 경로를 직접 입력하세요", "ファイルダイアログを使えません。パスを入力してください", "文件对话框不可用：请输入路径" },
    .{ "Sign in to an IR server first", "IR 서버에 먼저 로그인하세요", "先にIRサーバーへログインしてください", "请先登录 IR 服务器" },
    .{ "Could not start IR sync", "IR 동기화를 시작하지 못했어요", "IR同期を開始できません", "无法开始 IR 同步" },
    .{ "Uploading {d} of {d}...", "{1d}개 중 {0d}개 업로드 중...", "{1d} 件中 {0d} 件をアップロード中...", "正在上传 {0d}/{1d}..." },
    .{ "Talking to the IR server...", "IR 서버와 통신 중...", "IRサーバーと通信中...", "正在连接 IR 服务器..." },
    .{ "IR sync failed: {t}", "IR 동기화 실패: {t}", "IR同期失敗: {t}", "IR 同步失败：{t}" },
    .{ "Uploaded {d} replays, {d} unverified scores, {d} failed", "리플레이 {d}개, 미검증 점수 {d}개를 올렸어요. 실패 {d}개", "リプレイ {d} 件、未検証スコア {d} 件をアップロード、{d} 件失敗", "已上传 {d} 个回放、{d} 个未验证成绩，{d} 个失败" },
    .{ "Downloaded {d} scores", "점수 {d}개를 받았어요", "スコアを {d} 件ダウンロードしました", "已下载 {d} 个成绩" },
    .{ "actuon {s} is out: see Settings, Online", "actuon {s}이 나왔어요. 설정 > 온라인에서 확인하세요", "actuon {s} 公開: 設定、オンラインへ", "actuon {s} 已发布：见设置、在线" },
    .{ "Updated to {s}. Restart to use it.", "{s}로 업데이트했어요. 다시 시작하면 적용돼요.", "{s} に更新しました。再起動してください。", "已更新到 {s}。重启后使用。" },
    .{ "Update failed: {t}", "업데이트 실패: {t}", "更新失敗: {t}", "更新失败：{t}" },
    .{ "Checking...", "확인 중...", "確認中...", "正在检查..." },
    .{ "{s} (latest)", "{s} (최신)", "{s} (最新)", "{s}（最新）" },
    .{ "{s}, {s} available", "{s}, {s} 사용 가능", "{s}、{s} あり", "{s}，{s} 可用" },
    .{ "Downloading...", "다운로드 중...", "ダウンロード中...", "正在下载..." },
    .{ "Downloading {d}%", "다운로드 중 {d}%", "ダウンロード中 {d}%", "正在下载 {d}%" },
    .{ "Restart to use the new version", "다시 시작하면 새 버전이 적용돼요", "再起動で新バージョンを使います", "重启后使用新版本" },
    .{ "{s}, update failed", "{s}, 업데이트 실패", "{s}、更新失敗", "{s}，更新失败" },
    .{ "Could not open the browser", "브라우저를 열지 못했어요", "ブラウザを開けません", "无法打开浏览器" },
    .{ "Could not open the folder: {t}", "폴더를 열지 못했어요: {t}", "フォルダを開けません: {t}", "无法打开文件夹：{t}" },
    .{ "Set an IR server first, like https://ir.actuon.app", "IR 서버를 먼저 설정하세요. 예: https://ir.actuon.app", "先にIRサーバーを設定してください。例: https://ir.actuon.app", "请先设置 IR 服务器，例如 https://ir.actuon.app" },
    .{ "Could not reach the IR server", "IR 서버에 연결하지 못했어요", "IRサーバーに接続できません", "无法连接 IR 服务器" },
    .{ "Could not reach the IR server: {t}", "IR 서버에 연결하지 못했어요: {t}", "IRサーバーに接続できません: {t}", "无法连接 IR 服务器：{t}" },
    .{ "Signed in as {s}", "{s}(으)로 로그인했어요", "{s} としてログインしました", "已以 {s} 登录" },
    .{ "Out of memory, not signed in", "메모리가 부족해서 로그인하지 못했어요", "メモリ不足でログインできません", "内存不足，未登录" },
    .{ "Your IR name is now {s}", "IR 이름을 {s}(으)로 바꿨어요", "IR名を {s} に変更しました", "IR 名称已改为 {s}" },
    .{ "Set picked. A long song takes a moment to load before it plays.", "세트를 골랐어요. 곡이 길면 재생까지 조금 걸려요.", "セットを選びました。長い曲は再生前の読み込みに時間がかかります。", "已选择。较长的曲子播放前需要加载片刻。" },
    .{ "No audio outputs found", "오디오 출력을 찾지 못했어요", "音声出力が見つかりません", "未找到音频输出" },
    .{ "No sets yet: press Enter to pick a folder", "세트가 없어요. Enter로 폴더를 고르세요", "セットがありません。Enterでフォルダを選んでください", "暂无音效组：按 Enter 选择文件夹" },
    .{ "No sets in that folder", "이 폴더에는 세트가 없어요", "そのフォルダにセットがありません", "该文件夹中没有音效组" },
    .{ "No skins yet: put skin folders in {s}", "스킨이 없어요. 여기에 스킨 폴더를 넣으세요: {s}", "スキンがありません。スキンフォルダを入れてください: {s}", "暂无皮肤：请把皮肤文件夹放入 {s}" },
    .{ "Tables are still loading: try again in a moment", "난이도표를 불러오는 중이에요. 잠시 후 다시 해 주세요", "難易度表を読み込み中です。しばらくしてからやり直してください", "难度表仍在加载：请稍后再试" },
    .{ "Loading table...", "난이도표 불러오는 중...", "難易度表を読み込み中...", "正在加载难度表..." },
    .{ "Loading tables...", "난이도표들 불러오는 중...", "難易度表を読み込み中...", "正在加载难度表..." },
    .{ "Could not remove that table", "난이도표를 빼지 못했어요", "その難易度表を削除できません", "无法移除该难度表" },
    .{ "Table removed", "난이도표를 뺐어요", "難易度表を削除しました", "难度表已移除" },
    .{ "Import failed: {t}", "가져오기 실패: {t}", "取り込み失敗: {t}", "导入失败：{t}" },
    .{ "Imported {d} scores", "점수 {d}개를 가져왔어요", "スコアを {d} 件取り込みました", "已导入 {d} 个成绩" },
    .{ "Imported {d} scores, {d} charts not in library", "점수 {d}개를 가져왔어요. 라이브러리에 없는 채보 {d}개", "スコアを {d} 件取り込みました。ライブラリにない譜面 {d} 件", "已导入 {d} 个成绩，{d} 张谱面不在曲库中" },
    .{ "A table address starts with http:// or https://", "난이도표 주소는 http:// 또는 https://로 시작해야 해요", "難易度表のURLは http:// か https:// で始まります", "难度表地址须以 http:// 或 https:// 开头" },
    .{ "That table is already added", "이미 추가한 난이도표예요", "その難易度表は追加済みです", "该难度表已添加" },
    .{ "Type a number from {d} to {d}", "{d}~{d} 사이 숫자를 입력하세요", "{d} から {d} までの数字を入力してください", "请输入 {d} 到 {d} 的数字" },

    // IR account answers and the place on a chart's board.
    .{ "Name must be 1-32 characters", "이름은 1~32자로 해 주세요", "名前は1~32文字にしてください", "名称须为 1~32 个字符" },
    .{ "Name must be 1-32 characters and password at least 8", "이름은 1~32자, 비밀번호는 8자 이상으로 해 주세요", "名前は1~32文字、パスワードは8文字以上にしてください", "名称须为 1~32 个字符，密码至少 8 个字符" },
    .{ "Sign in again first", "다시 로그인해 주세요", "先にログインし直してください", "请先重新登录" },
    .{ "Wrong name or password", "이름이나 비밀번호가 틀렸어요", "名前またはパスワードが違います", "名称或密码错误" },
    .{ "That name is taken", "이미 있는 이름이에요", "その名前は使われています", "该名称已被占用" },
    .{ "Too many attempts, try again later", "시도가 너무 많아요. 나중에 다시 해 주세요", "試行回数が多すぎます。後でやり直してください", "尝试次数过多，请稍后再试" },
    .{ "The IR server refused", "IR 서버가 요청을 거부했어요", "IRサーバーに拒否されました", "IR 服务器拒绝了请求" },
    .{ "IR: loading...", "IR: 불러오는 중...", "IR: 読み込み中...", "IR：加载中..." },
    .{ "IR: unavailable", "IR: 사용할 수 없음", "IR: 利用不可", "IR：不可用" },
    .{ "IR: no scores yet", "IR: 아직 점수 없음", "IR: スコアなし", "IR：暂无成绩" },
    .{ "IR: {d} players", "IR: {d}명", "IR: {d} 人", "IR：{d} 名玩家" },
    .{ "IR: #{d} of {d}", "IR: {1d}명 중 {0d}위", "IR: {1d} 人中 {0d} 位", "IR：第 {0d} 名 / 共 {1d} 名" },
    .{ "IR: uploading...", "IR: 업로드 중...", "IR: アップロード中...", "IR：上传中..." },
    .{ "IR: upload failed", "IR: 업로드 실패", "IR: アップロード失敗", "IR：上传失败" },

    // Song select.
    .{ "Tables updated", "난이도표를 업데이트했어요", "難易度表を更新しました", "难度表已更新" },
    .{ "{d} of {d} tables failed to load", "난이도표 {1d}개 중 {0d}개를 불러오지 못했어요", "難易度表 {1d} 件中 {0d} 件の読み込みに失敗", "{1d} 个难度表中有 {0d} 个加载失败" },
    .{ "Tables failed to load", "난이도표를 불러오지 못했어요", "難易度表の読み込みに失敗", "难度表加载失败" },
    .{ "Courses", "코스", "コース", "课程" },
    .{ "Favorites", "즐겨찾기", "お気に入り", "收藏" },
    .{ "PRACTICE", "연습", "練習", "练习" },
    .{ "PRACTICE {d}%", "연습 {d}%", "練習 {d}%", "练习 {d}%" },
    .{ "START", "시작", "開始", "开始" },
    .{ "END", "끝", "終了", "结束" },
    .{ "CHART", "차트 기본값", "譜面の値", "谱面值" },
    .{ "Left and right change a value. Enter starts.", "좌우로 값을 바꾸고 Enter로 시작합니다.", "左右で値を変更し、Enterで開始します。", "左右键改变数值，回车键开始。" },
    .{ "Added to favorites", "즐겨찾기에 추가함", "お気に入りに追加", "已加入收藏" },
    .{ "Removed from favorites", "즐겨찾기에서 뺌", "お気に入りから削除", "已移出收藏" },
    .{ "Could not save the favorite", "즐겨찾기를 저장하지 못함", "お気に入りを保存できません", "无法保存收藏" },
    .{ "Screenshot saved", "스크린샷 저장함", "スクリーンショットを保存", "已保存截图" },
    .{ "Screenshot failed", "스크린샷 실패", "スクリーンショット失敗", "截图失败" },
    .{ "Target: my best", "목표: 내 최고 점수", "ターゲット: 自己ベスト", "目标：个人最佳" },
    .{ "Target: MAX", "목표: MAX", "ターゲット: MAX", "目标：MAX" },
    .{ "Target: AAA", "목표: AAA", "ターゲット: AAA", "目标：AAA" },
    .{ "Target: AA", "목표: AA", "ターゲット: AA", "目标：AA" },
    .{ "Target: A", "목표: A", "ターゲット: A", "目标：A" },
    .{ "Level {s}  ({d})", "레벨 {s}  ({d})", "レベル {s}  ({d})", "等级 {s}  ({d})" },
    .{ "SEARCH: {s}_", "검색: {s}_", "検索: {s}_", "搜索：{s}_" },
    .{ "Scanning... {d}", "검색 중... {d}", "スキャン中... {d}", "正在扫描... {d}" },
    .{ "No library folders yet. Press 6 to add one.", "라이브러리 폴더가 없어요. 6을 눌러 추가하세요.", "ライブラリフォルダがありません。6で追加してください。", "还没有曲库文件夹。按 6 添加。" },
    .{ "No library folders yet. Press F10 to add one.", "라이브러리 폴더가 없어요. F10을 눌러 추가하세요.", "ライブラリフォルダがありません。F10で追加してください。", "还没有曲库文件夹。按 F10 添加。" },
    .{ "No charts match.", "맞는 채보가 없어요.", "一致する譜面がありません。", "没有匹配的谱面。" },
    .{ "Nothing here.", "아무것도 없어요.", "何もありません。", "这里什么都没有。" },
    .{ "download this chart", "이 채보 받기", "この譜面をダウンロード", "下载此谱面" },
    .{ "open", "열기", "開く", "打开" },
    .{ "SORT", "정렬", "ソート", "排序" },
    .{ "TITLE", "제목", "タイトル", "标题" },
    .{ "ARTIST", "아티스트", "アーティスト", "艺术家" },
    .{ "LENGTH", "길이", "長さ", "时长" },
    .{ "LEVEL", "레벨", "レベル", "等级" },
    .{ "KEY MODE", "키 모드", "キーモード", "键位模式" },
    .{ "REPLAY", "리플레이", "リプレイ", "回放" },
    .{ "NONE", "없음", "なし", "无" },
    .{ "AUTOPLAY", "오토플레이", "オートプレイ", "自动游玩" },
    .{ "F6 Search", "F6 검색", "F6 検索", "F6 搜索" },
    .{ "F7 Rescan", "F7 다시 검색", "F7 再スキャン", "F7 重新扫描" },
    .{ "F8 Tables", "F8 난이도표", "F8 難易度表", "F8 难度表" },
    .{ "F10 Settings", "F10 설정", "F10 設定", "F10 设置" },
    .{ "R Replay", "R 리플레이", "R リプレイ", "R 回放" },
    .{ "V Versus", "V 대전", "V 対戦", "V 对战" },
    .{ "8 Folder", "8 폴더", "8 フォルダ", "8 文件夹" },
    .{ "Esc Back", "Esc 뒤로", "Esc 戻る", "Esc 返回" },
    .{ "{s} Open", "{s} 열기", "{s} 開く", "{s} 打开" },
    .{ "{s} Auto", "{s} 오토", "{s} オート", "{s} 自动" },
    .{ "{s} Replay", "{s} 리플레이", "{s} リプレイ", "{s} 回放" },
    .{ "{s} Back", "{s} 뒤로", "{s} 戻る", "{s} 返回" },
    .{ "{s}, {s} Scroll", "{s}, {s} 스크롤", "{s}, {s} スクロール", "{s}, {s} 滚动" },
    .{ "Hold {s} Options", "{s} 누른 채 옵션", "{s} 長押し オプション", "按住 {s} 选项" },
    .{ "Hold {s}+{s} or 5 Detail", "{s}+{s} 또는 5 누른 채 상세", "{s}+{s} か 5 長押し 詳細", "按住 {s}+{s} 或 5 详情" },
    .{ "0 Search", "0 검색", "0 検索", "0 搜索" },
    .{ "7 IR page", "7 IR 페이지", "7 IRページ", "7 IR 页面" },
    .{ "6 Key config", "6 키 설정", "6 キー設定", "6 按键设置" },
    .{ "Nothing to set here yet", "아직 설정할 게 없어요", "まだ設定項目がありません", "暂无可设置的内容" },
    .{ "{s}, {s}  DURATION  {d} ms", "{s}, {s}  표시 시간  {d} ms", "{s}, {s}  表示時間  {d} ms", "{s}, {s}  显示时长  {d} ms" },
    .{ "{s}, {s}  JUDGE OFFSET  {d} ms", "{s}, {s}  판정 오프셋  {d} ms", "{s}, {s}  判定オフセット  {d} ms", "{s}, {s}  判定偏移  {d} ms" },
    .{ "LIBRARY", "라이브러리", "ライブラリ", "曲库" },
    .{ "TABLE", "난이도표", "難易度表", "难度表" },
    .{ "COURSES", "코스", "コース", "课程" },
    .{ "Loading...", "불러오는 중...", "読み込み中...", "加载中..." },
    .{ "No tables yet. Add one in Settings, Tables.", "난이도표가 없어요. 설정 > 난이도표에서 추가하세요.", "難易度表がありません。設定の難易度表で追加してください。", "暂无难度表。请在设置的难度表中添加。" },
    .{ "Updating tables...", "난이도표 업데이트 중...", "難易度表を更新中...", "正在更新难度表..." },
    .{ "A download is already running", "이미 받는 중이에요", "すでにダウンロード中です", "已有下载正在进行" },
    .{ "Add a library folder first", "라이브러리 폴더를 먼저 추가하세요", "先にライブラリフォルダを追加してください", "请先添加曲库文件夹" },
    .{ "No download source for this chart", "이 채보를 받을 곳이 없어요", "この譜面のダウンロード元がありません", "此谱面没有下载来源" },
    .{ "Could not start download", "다운로드를 시작하지 못했어요", "ダウンロードを開始できません", "无法开始下载" },
    .{ "Extracting...", "압축 해제 중...", "展開中...", "正在解压..." },
    .{ "Download stalled: the server stopped sending", "다운로드가 멈췄어요. 서버가 전송을 멈췄어요", "ダウンロード停止: サーバーの送信が止まりました", "下载停滞：服务器停止发送" },
    .{ "Download finished", "다운로드 완료", "ダウンロード完了", "下载完成" },
    .{ "Download failed", "다운로드 실패", "ダウンロード失敗", "下载失败" },
    .{ "No replay in this slot", "이 슬롯에는 리플레이가 없어요", "このスロットにリプレイがありません", "此栏位没有回放" },
    .{ "Could not read this replay", "리플레이를 읽지 못했어요", "このリプレイを読めません", "无法读取此回放" },
    .{ "Set an IR server in settings first", "설정에서 IR 서버를 먼저 지정하세요", "先に設定でIRサーバーを指定してください", "请先在设置中指定 IR 服务器" },
    .{ "Ranking", "랭킹", "ランキング", "排名" },
    .{ "Table standings", "난이도표 순위", "難易度表順位", "难度表排名" },
    .{ "Rivals", "라이벌", "ライバル", "对手" },

    // Loading, play, pause and result.
    .{ "LOADING", "불러오는 중", "読み込み中", "加载中" },
    .{ "VERSUS", "대전", "対戦", "对战" },
    .{ "Room code", "방 코드", "ルームコード", "房间代码" },
    .{ "Select a chart first", "먼저 채보를 고르세요", "先に譜面を選んでください", "请先选择谱面" },
    .{ "Sign in to IR first", "먼저 IR에 로그인하세요", "先にIRにログインしてください", "请先登录 IR" },
    .{ "Could not reach the room", "방에 연결하지 못했어요", "ルームに接続できません", "无法连接房间" },
    .{ "You do not have this chart", "이 채보가 없어요", "この譜面を持っていません", "你没有这个谱面" },
    .{ "Connection to the room was lost", "방과 연결이 끊겼어요", "ルームとの接続が切れました", "与房间的连接已断开" },
    .{ "C: create a room for the selected chart", "C: 고른 채보로 방 만들기", "C: 選択中の譜面でルームを作成", "C: 用所选谱面创建房间" },
    .{ "ENTER: join a room by its code", "ENTER: 코드로 방 들어가기", "ENTER: コードでルームに参加", "ENTER: 用代码加入房间" },
    .{ "Connecting...", "연결하는 중...", "接続中...", "连接中..." },
    .{ "That room is full", "방이 꽉 찼어요", "ルームが満員です", "房间已满" },
    .{ "No room has that code", "그 코드의 방이 없어요", "そのコードのルームはありません", "没有该代码的房间" },
    .{ "That round has already started", "이번 판은 이미 시작했어요", "このラウンドは既に始まっています", "本轮已经开始" },
    .{ "ESC: leave", "ESC: 나가기", "ESC: 退出", "ESC: 退出" },
    .{ "HOST", "방장", "ホスト", "房主" },
    .{ "NO CHART", "채보 없음", "譜面なし", "无谱面" },
    .{ "ENTER: start. TAB: pick a chart, then the versus key.", "ENTER: 시작. TAB: 채보를 고른 뒤 V.", "ENTER: 開始。TAB: 譜面を選んでV。", "ENTER: 开始。TAB: 选谱面后按 V。" },
    .{ "Waiting for the host", "방장을 기다리는 중", "ホストを待っています", "等待房主" },
    .{ "L: move the score board in play", "L: 플레이 중 점수판 위치 바꾸기", "L: プレイ中のスコアボードを移動", "L: 移动游戏中的计分板" },
    .{ "Could not load that chart", "채보를 불러오지 못했어요", "その譜面を読み込めません", "无法加载该谱面" },
    .{ "NOT RECORDED", "기록되지 않음", "記録なし", "未记录" },
    .{ "NOT RECORDED: PAUSED", "기록되지 않음: 일시정지", "記録なし: 一時停止", "未记录：已暂停" },
    .{ "NOT RECORDED: SAVE FAILED", "기록되지 않음: 저장 실패", "記録なし: 保存失敗", "未记录：保存失败" },
    .{ "Settings could not be read: moved to config.json.bad", "설정을 읽지 못했어요: config.json.bad로 옮겼어요", "設定を読めませんでした: config.json.bad に移しました", "无法读取设置：已移至 config.json.bad" },
    .{ "{s}: SKIP", "{s}: 건너뛰기", "{s}: スキップ", "{s}：跳过" },
    .{ "{s}: BACK", "{s}: 뒤로", "{s}: 戻る", "{s}：返回" },
    .{ "The last run crashed: see crash-last.txt in the data folder", "지난번에 비정상 종료됐어요. 데이터 폴더의 crash-last.txt를 확인하세요", "前回の実行がクラッシュしました。データフォルダのcrash-last.txtを確認してください", "上次运行崩溃：请查看数据文件夹中的 crash-last.txt" },
    .{ "{d} SOUNDS MISSING", "소리 {d}개 없음", "音声 {d} 件不足", "缺少 {d} 个音频" },
    .{ "PAUSED", "일시정지", "一時停止", "暂停" },
    .{ "RESUME", "계속", "再開", "继续" },
    .{ "RETRY", "다시 하기", "リトライ", "重试" },
    .{ "QUIT", "그만두기", "終了", "退出" },
    .{ "Resuming will leave this play unrecorded", "계속하면 이번 플레이는 기록되지 않아요", "再開するとこのプレイは記録されません", "继续后本次游玩不会被记录" },
    .{ "Could not start course", "코스를 시작하지 못했어요", "コースを開始できません", "无法开始课程" },
    .{ "Course has charts missing from the library", "라이브러리에 없는 채보가 코스에 있어요", "コースの譜面にライブラリにないものがあります", "课程中有谱面不在曲库内" },

    // Skin settings and skins per screen.
    .{ "The built-in skin has no settings.", "내장 스킨은 설정이 없어요.", "内蔵スキンに設定はありません。", "内置皮肤没有设置项。" },
    .{ "This skin has no settings.", "이 스킨은 설정이 없어요.", "このスキンに設定はありません。", "此皮肤没有设置项。" },
    .{ "Skin settings", "스킨 설정", "スキン設定", "皮肤设置" },
    .{ "Left/Right changes the value. Changes show on song select and from the next play. Esc goes back.", "좌우 키로 값을 바꿔요. 곡 선택 화면과 다음 플레이부터 적용돼요. Esc로 돌아가요.", "左右で値を変更します。選曲と次のプレイから反映されます。Esc: 戻る。", "左右键更改数值。在选曲和下次游玩时生效。Esc 返回。" },
    .{ "Song select", "곡 선택", "選曲", "选曲" },
    .{ "Decide", "결정", "決定", "决定" },
    .{ "Result", "결과", "リザルト", "结算" },
    .{ "Play 7 keys", "플레이 7키", "プレイ 7鍵", "游玩 7 键" },
    .{ "Play 5 keys", "플레이 5키", "プレイ 5鍵", "游玩 5 键" },
    .{ "Play 14 keys", "플레이 14키", "プレイ 14鍵", "游玩 14 键" },
    .{ "Play 10 keys", "플레이 10키", "プレイ 10鍵", "游玩 10 键" },
    .{ "Play 9 buttons", "플레이 9버튼", "プレイ 9ボタン", "游玩 9 按钮" },
    .{ "Play 4 keys", "플레이 4키", "プレイ 4鍵", "游玩 4 键" },
    .{ "Play 6 keys", "플레이 6키", "プレイ 6鍵", "游玩 6 键" },
    .{ "Default ({s})", "기본값 ({s})", "既定 ({s})", "默认 ({s})" },
    .{ "Options", "옵션", "オプション", "选项" },
    .{ "Enter or click: pick a skin   Left/Right: step   O: its options   Esc: back", "Enter·클릭: 스킨 고르기   좌우: 넘기기   O: 옵션   Esc: 뒤로", "Enter・クリック: スキン選択   左右: 切替   O: オプション   Esc: 戻る", "Enter/点击：选择皮肤   左右：切换   O：选项   Esc：返回" },
};

/// The placeholders of a format, letters only: `{1d}` and `{d}` are the same one.
fn placeholders(text: []const u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}').?;
        out[n] = std.mem.trimStart(u8, rest[open + 1 .. close], "0123456789");
        n += 1;
        rest = rest[close + 1 ..];
    }
    std.mem.sort([]const u8, out[0..n], {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return out[0..n];
}

test "every string has text in every language, with the same placeholders" {
    for (rows) |r| {
        var want_buf: [8][]const u8 = undefined;
        const want = placeholders(r[0], &want_buf);
        for (r) |text| {
            try std.testing.expect(text.len > 0);
            var got_buf: [8][]const u8 = undefined;
            const got = placeholders(text, &got_buf);
            try std.testing.expectEqual(want.len, got.len);
            for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
        }
    }
}

test "no key is listed twice" {
    for (rows, 0..) |a, i| {
        for (rows[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a[0], b[0]));
    }
}

test "lookups follow the current language and reorder numbers" {
    defer current = .en;
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("IR: #3 of 12", try bufPrint(&buf, "IR: #{d} of {d}", .{ 3, 12 }));
    current = .ko;
    try std.testing.expectEqualStrings("IR: 12명 중 3위", try bufPrint(&buf, "IR: #{d} of {d}", .{ 3, 12 }));
    try std.testing.expectEqualStrings("설정", tr("Settings"));
    current = .zh;
    try std.testing.expectEqualStrings("设置", tr("Settings"));
}

test "an unknown saved language is not trusted" {
    try std.testing.expectEqual(Lang.ja, fromCode("ja").?);
    try std.testing.expect(fromCode("xx") == null);
    try std.testing.expect(fromCode("") == null);
    try std.testing.expectEqual(Lang.ko, resolve("ko"));
}
