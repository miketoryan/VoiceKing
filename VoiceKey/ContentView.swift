import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.handoffActive {
                HandoffView()
            } else {
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
    }
}

private struct HandoffView: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.indigo, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)
                Text("VK")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Text("VoiceKing")
                .font(.title2.bold())

            Text("正在启动语音输入…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
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
            .safeAreaInset(edge: .top) {
                HStack {
                    Spacer()
                    Text("v0.3.9 · build 16")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 16)
                }
                .background(.clear)
            }
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
                    Text("键盘空闲时麦克风保持关闭；点击语音后 VoiceKing 会短暂唤醒，在前台开始录音并立即返回，结束录音后关闭麦克风。")
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
                    Text("1. 在首页登录 ChatGPT。登录成功后会自动启动键盘服务。")
                    Text("2. 打开 iPhone 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → VoiceKing。")
                    Text("3. 打开 VoiceKing 的“允许完全访问”。")
                }

                Section("键盘使用") {
                    Text("VoiceKing 是纯语音键盘，不提供拼音或英文按键输入。")
                    Text("点击麦克风后会短暂唤醒 VoiceKing；录音开始后自动返回当前输入 App。")
                    Text("点击语音按钮开始录音，再点一次结束；识别完成后文字会自动插入当前输入框。")
                    Text("键盘顶部可切换智能/原文与中英文；底部地球按钮切换输入法，换行按钮插入换行，删除按钮可修正文字。")
                }

                Section("语音模式") {
                    Text("智能整理（默认）：添加标点和分段，删除无意义口头语与重复内容，修正明显语病，但不改变原意、不新增信息。")
                    Text("原文模式：只转录，尽量保留原话，适合会议和原始记录。")
                }

                Section("注意事项") {
                    Text("语音转录和智能整理需要连接 ChatGPT；普通文字输入请切换到苹果自带键盘。")
                    Text("VoiceKing 使用的 ChatGPT/Codex 接口未公开，未来可能变化。语音录音采用短暂打开 VoiceKing 并自动返回原 App 的方式。")
                }

                Section("版本") {
                    LabeledContent("VoiceKing", value: "0.3.9 · build 16")
                }
            }
            .navigationTitle("说明")
        }
    }
}
