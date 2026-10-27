import SwiftUI
import AVFoundation

struct VoiceExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var dataManager = DataManager.shared
    @StateObject private var speech = ExpenseSpeechRecorder()
    @State private var transcript = ""
    @State private var recordingPrefix = ""
    @State private var consent = false
    @State private var preparing = false
    @State private var drafts: [VoiceTransactionDraft] = []
    @State private var unresolved: [String] = []
    @State private var referenceDate = Date()
    @State private var prefill: VoiceExpensePrefill?
    @State private var error: String?
    @State private var savedCount = 0
    @State private var work: Task<Void, Never>?
    @State private var lastFingerprint = ""
    @State private var requestID = UUID()
    @State private var startedOnEntry = false
    var startListeningOnAppear = false
    var onSaved: () -> Void = {}

    private var busy: Bool { preparing || speech.isRecording || speech.isFinishing || speech.isAuthorizing }
    private var textIsValid: Bool { !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && transcript.count <= 4000 }

    var body: some View {
        NavigationStack {
            Form {
                Section {

                    VStack(spacing: 10) {
                        Button {
                            if speech.isRecording { speech.finish() }
                            else {
                                startListening()
                            }
                        } label: {
                            Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 68, height: 68)
                                .background(speech.isRecording ? Color.red : Color.accentColor, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(preparing || speech.isFinishing || speech.isAuthorizing)
                        .accessibilityLabel(speech.isRecording ? voiceText("Stop recording", "Остановить запись") : voiceText("Start recording", "Начать запись"))
                        .accessibilityIdentifier("voice.record")
                        Text(speech.isAuthorizing ? voiceText("Checking microphone permission…", "Проверка доступа к микрофону…") : speech.isRecording ? voiceText("Listening… tap to stop", "Слушаю… нажмите, чтобы остановить") : speech.isFinishing ? voiceText("Finishing…", "Завершение…") : voiceText("Tap and say your expenses", "Нажмите и назовите расходы"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("voice.status")
                        if let message = speech.message {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("voice.speech-message")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } footer: {
                    Text(voiceText("Speech is processed on this iPhone. You can also type or use the keyboard microphone.", "Речь распознаётся на этом iPhone. Можно также ввести текст или использовать микрофон клавиатуры."))
                }

                Section(voiceText("Your words", "Ваш текст")) {
                    TextEditor(text: $transcript)
                        .frame(minHeight: 110, maxHeight: 200)
                        .disabled(busy)
                        .accessibilityLabel(voiceText("Expense transcript", "Текст расходов"))
                        .accessibilityIdentifier("voice.transcript")
                    if transcript.isEmpty {
                        Text(voiceText("Yesterday I spent 15,800 som on a taxi and 35,000 on lunch.", "Вчера потратил 15 800 сум на такси и 35 000 на обед."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if transcript.count > 4000 {
                        Text(voiceText("Keep the text under 4,000 characters.", "Текст должен быть не длиннее 4 000 символов."))
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Toggle(voiceText("Allow AI to prepare these expenses", "Разрешить ИИ подготовить расходы"), isOn: $consent)
                        .disabled(busy)
                    Button(action: prepareDrafts) {
                        HStack {
                            if preparing { ProgressView() }
                            Text(preparing ? voiceText("Preparing drafts…", "Подготовка черновиков…") : voiceText("Review expenses", "Проверить расходы"))
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(busy || !textIsValid || !consent)
                    .accessibilityIdentifier("voice.review")
                } footer: {
                    Text(voiceText("Only this text, category names, currency, date and timezone go through Cenzio's server to OpenRouter/OpenAI. No audio or expense history is sent. AI can make mistakes; nothing is saved until you review and tap Save.", "Только этот текст, названия категорий, валюта, дата и часовой пояс отправляются через сервер Cenzio в OpenRouter/OpenAI. Аудио и история расходов не передаются. ИИ может ошибаться: запись сохраняется только после проверки и нажатия «Сохранить»."))
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("voice.draft-error")
                    }
                }

                if !drafts.isEmpty {
                    Section(voiceText("Review one expense at a time", "Проверьте каждый расход")) {
                        ForEach(drafts) { draft in draftRow(draft) }
                    }
                }
                if !unresolved.isEmpty {
                    Section(voiceText("Needs your attention", "Нужна ваша проверка")) {
                        ForEach(Array(unresolved.enumerated()), id: \.offset) { _, item in
                            Text(item).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if savedCount > 0 {
                    Section {
                        Text(voiceText("Saved: \(savedCount). Remaining drafts are not saved.", "Сохранено: \(savedCount). Остальные черновики не сохранены."))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(voiceText("Add by voice", "Добавить голосом"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(voiceText("Done", "Готово")) { dismiss() }
                }
            }
            .sheet(item: $prefill) { item in
                AddExpenseView(prefill: item) {
                    drafts.removeAll { $0.id == item.id }
                    savedCount += 1
                    onSaved()
                }
            }
            .onChange(of: speech.transcript) { _, text in
                guard !text.isEmpty else { return }
                transcript = recordingPrefix.isEmpty ? text : recordingPrefix + " " + text
            }
            .onChange(of: transcript) { _, _ in
                drafts = []
                unresolved = []
                error = nil
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { stopWork() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: rawType) == .began,
                      speech.isRecording || speech.isFinishing || speech.isAuthorizing else { return }
                work?.cancel()
                speech.cancel()
                speech.message = voiceText("Microphone interrupted by another app or a call. Tap the microphone to try again.", "Микрофон прерван другим приложением или звонком. Нажмите на микрофон, чтобы повторить.")
            }
            .onDisappear { stopWork() }
            .onAppear {
                guard startListeningOnAppear, !startedOnEntry else { return }
                startedOnEntry = true
                startListening()
            }
        }
    }

    private func startListening() {
        guard !busy else { return }
        recordingPrefix = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        work = Task { await speech.start(locale: InlineVoiceExpenseController.recognitionLocale) }
    }

    private func draftRow(_ draft: VoiceTransactionDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(draft.title ?? voiceText("Expense", "Расход")).font(.headline)
                Spacer()
                Text(amountLabel(draft)).monospacedDigit().fontWeight(.semibold)
            }
            if let phrase = draft.dateExpression {
                Text(phrase).font(.subheadline).foregroundStyle(.secondary)
            }
            if let id = draft.categoryID, let category = dataManager.userCategories.first(where: { $0.id.uuidString.lowercased() == id }) {
                Text(category.name).font(.subheadline).foregroundStyle(.secondary)
            }
            if !draft.ambiguousFields.isEmpty || draft.amountDecimal == nil {
                Text(voiceText("Amount needs confirmation. Enter it on the next screen.", "Сумма требует подтверждения. Введите её на следующем экране."))
                    .font(.footnote).foregroundStyle(.orange)
            }
            if draft.canReviewAsExpense(currency: dataManager.user.currency.rawValue) {
                Button(voiceText("Review and save", "Проверить и сохранить")) {
                    prefill = VoiceExpensePrefill(draft: draft, referenceDate: referenceDate)
                }
            } else {
                Text(voiceText("Not saved: income, loans, card tracking and foreign-currency conversion are not supported here yet.", "Не сохранено: доходы, долги, учёт карт и конвертация валют пока не поддерживаются."))
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }

    private func amountLabel(_ draft: VoiceTransactionDraft) -> String {
        guard let amount = VoiceDraftValidation.amount(draft.amountDecimal) else { return voiceText("Set amount", "Укажите сумму") }
        if draft.currency == dataManager.user.currency.rawValue {
            return CurrencyFormatter.format(amount, currency: dataManager.user.currency)
        }
        return "\(AmountInputFormatter.formatValue(amount, maxFractionDigits: 6)) \(draft.currency ?? "—")"
    }

    private func prepareDrafts() {
        guard !busy, textIsValid, consent else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let categories = dataManager.userCategories
        let currency = dataManager.user.currency
        referenceDate = Date()
        let day = Calendar.current.startOfDay(for: referenceDate).timeIntervalSince1970
        let fingerprint = text + currency.rawValue + String(day) + TimeZone.current.identifier + categories.map { $0.id.uuidString + $0.name }.joined(separator: "|")
        if fingerprint != lastFingerprint { requestID = UUID(); lastFingerprint = fingerprint }
        error = nil
        preparing = true
        work = Task {
            defer { preparing = false }
            do {
                let response = try await VoiceAPI.drafts(text: text, categories: categories, currency: currency, reference: referenceDate, requestID: requestID)
                try Task.checkCancellation()
                drafts = response.transactions
                unresolved = response.unresolvedFields
                if drafts.isEmpty && unresolved.isEmpty {
                    error = voiceText("No expenses found. Include an amount and what you paid for.", "Расходы не найдены. Назовите сумму и за что заплатили.")
                }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func stopWork() {
        work?.cancel()
        speech.cancel()
        preparing = false
    }
}
