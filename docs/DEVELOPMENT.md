# 本地构建与验证

在装有完整 Xcode 的 Mac 上，于项目根目录运行：

```sh
bash tools/build.sh
dist/Fengdu.app/Contents/MacOS/Fengdu --self-test
dist/Fengdu.app/Contents/MacOS/Fengdu --ui-test
python3 Tests/test_ipc.py
bash tools/package.sh
```

上述测试使用模拟硬件，不写入真实风扇。可用 `--demo` 打开演示面板，或用 `--diagnose` 查看本机只读诊断。磁盘映像和校验文件输出到 `build/release/`。

标签构建核对版本、测试、打包并创建 GitHub Release；发布文案位于 `docs/releases/<标签>.md`。
