#!/bin/zsh
# 独立试用包；绝不启动 dist 中的正式包。
set -euo pipefail
cd "${0:A:h}/.."
NAME=default
COUNT=3
MEASURE=0
RESET=0
BUILD=1
ACTION=launch
PROJECTS=""
while (( $# )); do
  case "$1" in
    --name) NAME="${2:?缺少名字}"; shift ;;
    --count) COUNT="${2:?缺少数量}"; shift ;;
    --project) PROJECTS+="${2:?缺少项目路径}"$'\n'; shift ;;
    --measure) MEASURE=1 ;;
    --reset) RESET=1 ;;
    --no-build) BUILD=0 ;;
    --snapshot) ACTION=snapshot ;;
    --verify) ACTION=verify ;;
    --help) echo 'trial.sh [--name 名字] [--count 数量 | --project 项目路径（可重复）] [--reset] [--measure] [--no-build] [--snapshot | --verify]'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
  shift
done
[[ "$COUNT" == <-> && "$COUNT" -gt 0 ]] || { echo '数量必须为正整数'; exit 1; }
[[ -n "$NAME" && "$NAME" != *[^a-zA-Z0-9_-]* ]] || { echo '名字只允许字母、数字、下划线和短横线'; exit 1; }
if [[ "$ACTION" != launch ]]; then
  python3 - "$ACTION" "$NAME" <<'PY'
import json, os, pathlib, stat, sys, tempfile
source = pathlib.Path.home() / 'Library/Application Support/软件指南生成器（原生版）'
settings = json.loads((source / 'settings.json').read_text())
workspace = pathlib.Path(settings['workspaceDir']).expanduser().resolve()
# 只在本机临时目录写核对结果；正式目录只做 lstat/scandir。
folder = pathlib.Path(tempfile.gettempdir()) / ('manual-studio-trial-audit-' + str(os.getuid()))
folder.mkdir(mode=0o700, exist_ok=True)
if folder.is_symlink() or folder.stat().st_uid != os.getuid():
    raise SystemExit('核对目录不安全')
snapshot = folder / (sys.argv[2] + '.json')
def scan(root):
    result = {}
    def visit(path):
        st = path.lstat()
        result[str(path)] = [st.st_size, st.st_mtime_ns, stat.S_IFMT(st.st_mode)]
        if stat.S_ISDIR(st.st_mode):
            for child in sorted(path.iterdir()): visit(child)
    visit(root)
    return result
current = scan(source) | scan(workspace)
if sys.argv[1] == 'snapshot':
    if snapshot.is_symlink(): raise SystemExit('核对文件不安全')
    snapshot.write_text(json.dumps(current, ensure_ascii=False, sort_keys=True))
    print('已记录正式数据和正式工作区文件清单：', len(current), '项；', snapshot)
else:
    old = json.loads(snapshot.read_text())
    changes = [p for p in sorted(old.keys() | current.keys()) if old.get(p) != current.get(p)]
    if changes:
        print('发现差异：'); print('\n'.join(changes)); raise SystemExit(1)
    print('无差异')
PY
  exit
fi
DATA="$HOME/Library/Application Support/软件指南生成器 试用-$NAME"
(( MEASURE )) && DATA+="-measure"
# 不在脚本中删除数据；核心库验证实际路径及模式标记后才处理 reset。
if (( BUILD )); then
  BUILD_LOG=$(mktemp -t manual-studio-trial-build)
  trap 'rm -f "$BUILD_LOG"' EXIT
  scripts/build-app.sh | tee "$BUILD_LOG"
  grep -q 'BUILD SUCCEEDED' "$BUILD_LOG" || { echo '本次编译未成功，拒绝使用旧产物'; exit 1; }
  rm -f "$BUILD_LOG"
fi
APP="dist/软件指南生成器 试用-$NAME.app"
# 同一包运行时拒绝覆盖；只检查该 worktree 的试用可执行文件。
if pgrep -f "${PWD}/${APP}/Contents/MacOS/" >/dev/null; then
  echo '请先退出这份试用版再重新启动'; exit 1
fi
rm -rf "$APP"
ditto 'dist/软件指南生成器.app' "$APP"
PLIST="$APP/Contents/Info.plist"
BASE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $BASE.$NAME.trial" "$PLIST"
/usr/libexec/PlistBuddy -c 'Set CFBundleName 软件指南生成器 试用' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add CFBundleDisplayName string 软件指南生成器 试用' "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Set CFBundleDisplayName 软件指南生成器 试用' "$PLIST"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
EXE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")
echo "试用数据：$DATA"
export MS_DATA_DIR="$DATA" MS_TRIAL=1 MS_TRIAL_MEASURE="$MEASURE" MS_TRIAL_RESET="$RESET" MS_TRIAL_COUNT="$COUNT" MS_TRIAL_PROJECTS="$PROJECTS"
exec "$PWD/$APP/Contents/MacOS/$EXE"
