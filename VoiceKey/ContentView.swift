import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            HomeView(model: model)
                .tabItem { Label("首页", systemImage: "house.fill") }

            SettingsView(model: model)
                .tabItem { Label("设置", systemImage: "gearshape.fill") }

            HelpView()
                .tabItem { Label("说明", systemImage: "book.closed.fill") }
        }
    }
}

private struct HomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("GPT 账号") {
                    LabeledContent("账号") {
                        Text(model.signedIn ? (model.accountEmail ?? "已登录") : "未登录")
                            .foregroundStyle(.secondary)
                    }

                    if model.signedIn {
                        Button("退出登录", role: .destructive) { model.signOut() }
                    } else {
                        Button("登录 ChatGPT") {
                            Task { await model.signIn() }
                        }
                    }
                }

                Section("软件状态") {
                    LabeledContent("键盘服务") {
                        Label(
                            model.serviceReady ? "运行中" : "已停止",
                            systemImage: model.serviceReady
                                ? "checkmark.circle.fill"
                                : "pause.circle"
                        )
                        .foregroundStyle(model.serviceReady ? Color.green : Color.secondary)
                    }

                    Text(model.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let error = model.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if model.serviceReady {
                        Button("停止键盘服务", role: .destructive) { model.stopService() }
                    } else {
                        Button("启动键盘服务") {
                            Task { await model.startService() }
                        }
                        .disabled(!model.signedIn)
                    }
                }

                Section("免跳转录音") {
                    PiPPreviewView(service: model.pictureInPictureService)
                        .frame(height: 140)

                    LabeledContent("状态") {
                        Label(
                            model.pictureInPictureActive ? "已开启" : "未开启",
                            systemImage: model.pictureInPictureActive
                                ? "mic.fill"
                                : "mic"
                        )
                        .foregroundStyle(
                            model.pictureInPictureActive ? Color.green : Color.secondary
                        )
                    }

                    Text("参考 Typeless 的交互：开启后保留一个画中画窗口，可拖到屏幕左右边缘隐藏。之后在其他 App 的 VoiceKing 键盘里点击语音，正常情况下无需再跳回 VoiceKing。麦克风只有点击“开始说话”后才开启。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if model.pictureInPictureActive {
                        Button("关闭免跳转模式", role: .destructive) {
                            model.disableSkipAppSwitching()
                        }
                    } else {
                        Button("开启免跳转模式") {
                            Task { await model.enableSkipAppSwitching() }
                        }
                        .disabled(!model.signedIn || !model.pictureInPictureSupported)
                    }

                    if !model.pictureInPictureSupported {
                        Text("当前设备不支持系统画中画。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("VoiceKing")
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("语音识别语言") {
                    Picker("识别语言", selection: $model.preferredKeyboardLanguage) {
                        Text("中文").tag(KeyboardLanguage.chinese)
                        Text("English").tag(KeyboardLanguage.english)
                    }
                    .pickerStyle(.segmented)

                    Text("这里决定下一次语音输入使用中文识别还是英文识别。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("语音模式") {
                    LabeledContent("默认模式", value: "智能整理")
                    Text("也可以直接在键盘顶部切换为“原文模式”。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("麦克风") {
                    Text("开启“免跳转录音”后，键盘空闲时麦克风保持关闭；只有点击“开始说话”才启用麦克风，结束录音后立即关闭。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("如果画中画没有开启或被系统关闭，VoiceKing 会退回普通待机；服务真正休眠时才使用打开 App 的兜底流程。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}

private struct HelpView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("首次设置") {
                    Text("1. 在首页登录 ChatGPT 并启动键盘服务。")
                    Text("2. 打开 iPhone 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → VoiceKing。")
                    Text("3. 打开 VoiceKing 的“允许完全访问”。")
                }

                Section("键盘使用") {
                    Text("VoiceKing 是纯语音键盘，不提供拼音或英文按键输入。")
                    Text("建议先在首页开启“免跳转录音”，把 VoiceKing 的画中画拖到屏幕左右边缘隐藏。")
                    Text("键盘显示实心麦克风时代表免跳转已就绪；空心麦克风代表可能需要唤醒 VoiceKing。")
                    Text("点击语音按钮开始录音，再点一次结束；识别完成后文字会自动插入当前输入框。")
                    Text("左侧地球按钮用于切换其他输入法，右侧删除按钮可以删除识别错误的文字。")
                }

                Section("语音模式") {
                    Text("智能整理（默认）：添加标点和分段，删除无意义口头语与重复内容，修正明显语病，但不改变原意、不新增信息。")
                    Text("原文模式：只转录，尽量保留原话，适合会议和原始记录。")
                }

                Section("注意事项") {
                    Text("语音转录和智能整理需要连接 ChatGPT；普通文字输入请切换到苹果自带键盘。")
                    Text("VoiceKing 使用的 ChatGPT/Codex 接口未公开，未来可能变化。画中画是免跳转主路径；自动打开/返回原 App 仅作为个人侧载兜底功能。")
                }

                Section("版本") {
                    LabeledContent("VoiceKing", value: "0.3.6 Typeless-PiP 测试版")
                }
            }
            .navigationTitle("说明")
        }
    }
}
