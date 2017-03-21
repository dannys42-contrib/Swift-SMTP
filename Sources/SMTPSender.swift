//
//  SMTPSend.swift
//  KituraSMTP
//
//  Created by Quan Vo on 3/16/17.
//
//

import Foundation
import Socket

#if os(Linux)
    import Dispatch
#endif

public typealias Progress = ((Mail, Error?) -> Void)?
public typealias Completion = (([Mail], [(Mail, Error)]) -> Void)?

class SMTPSender {
    fileprivate var socket: SMTPSocket
    fileprivate var config: SMTPConfig
    fileprivate var pending: [Mail]
    fileprivate var progress: Progress
    fileprivate var completion: Completion
    fileprivate let queue = DispatchQueue(label: "com.ibm.Kitura-SMTP.queue")
    fileprivate var sent = [Mail]()
    fileprivate var failed = [(Mail, Error)]()
    
    init(config: SMTPConfig, pending: [Mail], progress: Progress, completion: Completion) throws {
        socket = try SMTPSocket()
        self.config = config
        self.pending = pending
        self.progress = progress
        self.completion = completion
    }
    
    func resume() {
        queue.async {
            do {
                self.socket = try SMTPLogin(config: self.config, socket: self.socket).login()
            } catch {
                self.completion?([], self.pending.map { ($0, error) })
                self.socket.close()
                self.cleanUp()
                return
            }
            self.sendNext()
        }
    }
    
    deinit {
        socket.close()
    }
}

private extension SMTPSender {
    func sendNext() {
        if pending.isEmpty {
            completion?(sent, failed)
            try? quit()
            cleanUp()
            return
        }
        
        let mail = pending.removeFirst()
        
        do {
            try send(mail)
            sent.append(mail)
            progress?(mail, nil)
            
        } catch {
            failed.append((mail, error))
            progress?(mail, error)
        }
        
        queue.async { self.sendNext() }
    }
    
    func cleanUp() {
        progress = nil
        completion = nil
    }
    
    func quit() throws {
        defer { socket.close() }
        return try socket.send(.quit)
    }
}

private extension SMTPSender {
    func send(_ mail: Mail) throws {
        try validateEmails(mail.to.map { $0.email })
        try sendMail(mail.from.email)
        try sendTo(mail.to + mail.cc + mail.bcc)
        try data()
        try SMTPDataSender(mail: mail, socket: socket).send()
        try dataEnd()
    }
    
    private func validateEmails(_ emails: [String]) throws {
        for email in emails {
            try email.validateEmail()
        }
    }
    
    private func sendMail(_ from: String) throws {
        return try socket.send(.mail(from))
    }
    
    private func sendTo(_ recipients: [User]) throws {
        for user in recipients {
            let _: Void = try socket.send(.rcpt(user.email))
        }
    }
    
    private func data() throws {
        return try socket.send(.data)
    }
    
    private func dataEnd() throws {
        return try socket.send(.dataEnd)
    }
}

private extension String {
    func validateEmail() throws {
        let emailRegEx = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        let emailTest = NSPredicate(format:"SELF MATCHES %@", emailRegEx)
        guard emailTest.evaluate(with: self) else {
            throw SMTPError(.invalidEmail(self))
        }
    }
}

