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
                Section("键盘语言") {
                    Picker("默认语言", selection: $model.preferredKeyboardLanguage) {
                        Text("中文").tag(KeyboardLanguage.chinese)
                        Text("English").tag(KeyboardLanguage.english)
                    }
                    .pickerStyle(.segmented)

                    Text("键盘上的“中/英”键可以随时切换。这里设置下次打开键盘时的默认语言，同时决定语音识别使用中文还是英文。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("语音模式") {
                    LabeledContent("默认模式", value: "智能整理")
                    Text("也可以直接在键盘顶部切换为“原文模式”。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("词库") {
                    LabeledContent("中文词库", value: "自动更新")
                    LabeledContent("英文词库", value: "iOS 本地词典")
                    Text("有网络并允许完全访问时，键盘每 7 天检查一次中文扩展词库；更新失败不会影响本地输入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("麦克风") {
                    Text("离开输入页面或切换到其他键盘约 10 秒后，VoiceKing 会关闭麦克风。再次点击语音按钮时会自动唤醒。")
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
                    Text("中文模式：输入拼音，从候选栏选择文字；空格会选择第一个候选。")
                    Text("English 模式：使用 QWERTY 键盘直接输入，可使用 Shift、删除、空格和回车。")
                    Text("识别结果插入后，可以直接用同一个键盘删除并修改，不必切换输入法。")
                }

                Section("语音模式") {
                    Text("智能整理（默认）：添加标点和分段，删除无意义口头语与重复内容，修正明显语病，但不改变原意、不新增信息。")
                    Text("原文模式：只转录，尽量保留原话，适合会议和原始记录。")
                }

                Section("注意事项") {
                    Text("中文拼音候选在本机生成；联网时 VoiceKing 可以更新扩展词库。语音转录和智能整理需要连接 ChatGPT。")
                    Text("VoiceKing 使用的 ChatGPT/Codex 接口未公开，未来可能变化。自动返回输入页面是个人侧载功能，不用于 App Store 发布。")
                }

                Section("版本") {
                    LabeledContent("VoiceKing", value: "0.3 测试版")
                }
            }
            .navigationTitle("说明")
        }
    }
}
