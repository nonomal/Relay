//
//  FeedbackMail.swift
//  Relay
//
//  意见反馈：唤起系统自带邮件撰写页，预填收件人 / 主题 / 正文（含版本与机型，便于定位），
//  并自动附上应用日志文件，方便开发者排查问题。
//  首选 MFMailComposeViewController（应用内原生撰写）；无 Apple Mail 账户时回退 mailto:。
//

import SwiftUI
import MessageUI
import UIKit

/// 反馈邮件的收件人与预填内容。
enum FeedbackMail {
    /// 开发者收件邮箱。
    static let recipient = "nagara.inbox@gmail.com"

    /// 附件文件名。
    static let logAttachmentName = "relay.log"

    /// "1.0（7）" —— marketing version + build。
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v)（\(b)）"
    }

    static var subject: String { "Relay 意见反馈 · v\(appVersion)" }

    /// 正文模板：用户描述区 + 可保留的环境信息尾注。
    static var body: String {
        """
        请在此描述你遇到的问题或建议：


        ————————————————
        以下信息有助于定位问题（可保留）
        版本：\(appVersion)
        机型：\(deviceModel)
        系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        ————————————————
        """
    }

    /// 机型标识（如 iPhone18,1），取不到则退回通用 model。
    private static var deviceModel: String {
        var sys = utsname()
        uname(&sys)
        let id = Mirror(reflecting: sys.machine).children.compactMap { el -> String? in
            guard let v = el.value as? Int8, v != 0 else { return nil }
            return String(UnicodeScalar(UInt8(v)))
        }.joined()
        return id.isEmpty ? UIDevice.current.model : id
    }

    /// 无 Apple Mail 时的回退链接，交给系统默认邮件 App。
    /// 注意：mailto: 无法携带附件，此路径下日志不随邮件发送。
    static var mailtoURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = recipient
        c.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return c.url
    }
}

/// MFMailComposeViewController 的 SwiftUI 封装，用 `.sheet` 呈现。
/// 撰写页会自动附上应用日志文件（若存在）。
struct MailComposeView: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    /// 作为附件的日志数据；为 nil 时不添加附件。
    var logData: Data?
    var logFileName: String = FeedbackMail.logAttachmentName
    /// 用户发送 / 取消 / 出错后回调（由外层置 sheet binding 为 false 关闭）。
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([recipient])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        if let logData, !logData.isEmpty {
            vc.addAttachmentData(logData, mimeType: "text/plain", fileName: logFileName)
        }
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            onFinish()
        }
    }
}
