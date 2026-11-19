import Contacts
import Foundation
import UIKit

struct PhoneCallTarget: Equatable, Sendable {
    let displayName: String
    let phoneNumber: String
}

enum PhoneCallError: LocalizedError {
    case contactsPermissionDenied
    case contactNotFound(String)
    case ambiguousContacts([String])
    case phoneNumberMissing(String)
    case invalidPhoneNumber
    case unableToOpenPhone

    var errorDescription: String? {
        switch self {
        case .contactsPermissionDenied:
            return "연락처 접근 권한이 필요합니다. 설정에서 JARVIS의 연락처 접근을 허용해주세요."
        case .contactNotFound(let name):
            return "연락처에서 \(name)을 찾지 못했습니다."
        case .ambiguousContacts(let names):
            return "\(names.joined(separator: ", ")) 중 누구인지 확실하지 않습니다. 연락처 이름을 다시 말씀해주세요."
        case .phoneNumberMissing(let name):
            return "\(name)의 연락처에 전화번호가 없습니다."
        case .invalidPhoneNumber:
            return "전화번호를 확인하지 못했습니다."
        case .unableToOpenPhone:
            return "전화 앱을 열지 못했습니다."
        }
    }
}

@MainActor
final class PhoneCallService {
    private let contactStore = CNContactStore()
    private let nameMatcher = ContactNameMatcher()

    func resolve(recipient rawRecipient: String) async throws -> PhoneCallTarget {
        let recipient = rawRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty else { throw PhoneCallError.invalidPhoneNumber }

        if isDirectPhoneNumber(recipient) {
            guard let phoneNumber = sanitizedPhoneNumber(recipient) else {
                throw PhoneCallError.invalidPhoneNumber
            }
            return PhoneCallTarget(displayName: recipient, phoneNumber: phoneNumber)
        }

        let granted = try await contactStore.requestAccess(for: .contacts)
        guard granted else { throw PhoneCallError.contactsPermissionDenied }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        let contacts = try allContacts(keysToFetch: keys)
        guard let contact = try bestMatch(for: recipient, in: contacts) else {
            throw PhoneCallError.contactNotFound(recipient)
        }
        guard let phoneNumber = preferredPhoneNumber(from: contact) else {
            throw PhoneCallError.phoneNumberMissing(displayName(for: contact, fallback: recipient))
        }

        return PhoneCallTarget(
            displayName: displayName(for: contact, fallback: recipient),
            phoneNumber: phoneNumber
        )
    }

    func call(_ target: PhoneCallTarget) async -> ToolExecutionResult<Void> {
        guard let url = URL(string: "tel:\(target.phoneNumber)"),
              await UIApplication.shared.open(url) else {
            return .failed(
                message: PhoneCallError.unableToOpenPhone.localizedDescription,
                retryable: true
            )
        }
        return .handedOff(())
    }

    private func allContacts(keysToFetch keys: [CNKeyDescriptor]) throws -> [CNContact] {
        var contacts: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try contactStore.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }
        return contacts
    }

    private func bestMatch(for query: String, in contacts: [CNContact]) throws -> CNContact? {
        let scored = contacts.compactMap { contact -> (contact: CNContact, score: Double)? in
            guard contact.phoneNumbers.contains(where: {
                sanitizedPhoneNumber($0.value.stringValue) != nil
            }) else { return nil }
            let score = candidateNames(for: contact)
                .map { nameMatcher.similarity(query: query, candidate: $0) }
                .max() ?? 0
            return (contact, score)
        }
        .sorted { $0.score > $1.score }

        guard let best = scored.first,
              nameMatcher.isAcceptable(score: best.score, query: query) else {
            return nil
        }

        if best.score < 1,
           let second = scored.dropFirst().first,
           best.score - second.score < 0.08 {
            let names = [best.contact, second.contact].map {
                displayName(for: $0, fallback: query)
            }
            throw PhoneCallError.ambiguousContacts(names)
        }
        return best.contact
    }

    private func candidateNames(for contact: CNContact) -> [String] {
        [
            "\(contact.familyName)\(contact.givenName)",
            "\(contact.givenName)\(contact.familyName)",
            contact.nickname,
            contact.organizationName
        ].filter { !$0.isEmpty }
    }

    private func displayName(for contact: CNContact, fallback: String) -> String {
        candidateNames(for: contact).first ?? fallback
    }

    private func preferredPhoneNumber(from contact: CNContact) -> String? {
        let sortedNumbers = contact.phoneNumbers.sorted { lhs, rhs in
            self.phoneLabelScore(lhs.label) > self.phoneLabelScore(rhs.label)
        }
        return sortedNumbers.lazy.compactMap {
            self.sanitizedPhoneNumber($0.value.stringValue)
        }.first
    }

    private func phoneLabelScore(_ label: String?) -> Int {
        switch label {
        case CNLabelPhoneNumberiPhone, CNLabelPhoneNumberMobile:
            return 2
        default:
            return 1
        }
    }

    private func isDirectPhoneNumber(_ value: String) -> Bool {
        let allowedCharacters = CharacterSet(charactersIn: "+0123456789-() ")
        return value.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
            && value.filter(\.isNumber).count >= 3
    }

    private func sanitizedPhoneNumber(_ value: String) -> String? {
        let hasLeadingPlus = value.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        let digits = value.filter(\.isNumber)
        guard digits.count >= 3 else { return nil }
        return hasLeadingPlus ? "+\(digits)" : digits
    }
}
