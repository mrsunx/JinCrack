//
//  main.swift
//  JinCrack
//
//  Created by zizo on 2023/9/8.
//

import Foundation
import XMLParsing
import Zip
import SwiftyJSON
import SwifterSwift

do {
    var courseIds = try JSONSerialization.jsonObject(with: try Data(contentsOf: URL(filePath: FileManager.default.currentDirectoryPath).appending(component: "ids.json"))) as? [Int] ?? []

    while !courseIds.isEmpty {

        let id = courseIds.first!

        var request = URLRequest(url: URL(string: "http://www.jinkaodian.com/CL.ExamWebService/ExamJsonService.asmx")!)
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = "<?xml version=\"1.0\" encoding=\"utf-8\"?><soap:Envelope xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\"><soap:Header><MGSoapHeader xmlns=\"http://tempuri.org/\"><UserID>ttexam</UserID><Password>ttexam123</Password> </MGSoapHeader></soap:Header><soap:Body><GetCourseUpdateName xmlns=\"http://tempuri.org/\"><courseId>\(id)</courseId><district></district><courseType>0</courseType></GetCourseUpdateName></soap:Body></soap:Envelope>".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard 200..<300 ~= (response as? HTTPURLResponse)?.statusCode ?? 0 else {
            fatalError("请求结果错误: \((response as? HTTPURLResponse)?.statusCode)")
        }

        // 解析资源id
        guard
            let responseXML = String(data: data, encoding: .utf8),
            let results = responseXML.firstMatch(of: /<GetCourseUpdateNameResult>(?<filename>.+?)<\/GetCourseUpdateNameResult>/)
        else {
            fatalError("XML解析错误")
        }
        let filename = String(results.filename)
            .replacingOccurrences(of: "</GetCourseUpdateNameResult>", with: "")
            .replacingOccurrences(of: "<GetCourseUpdateNameResult>", with: "")

        // 下载资源
        let (localURL, urlResponse) = try await URLSession.shared.download(for: URLRequest(url: URL(string: "http://www.jinkaodian.com/CL.ExamWebService/subject/\(filename).zip")!))
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            fatalError("下载错误，找不到文件, \(localURL), \(urlResponse)")
        }
        let destination = URL(filePath: FileManager.default.currentDirectoryPath).appending(component: "Resources").appending(component: filename).appendingPathExtension("zip")
        try FileManager.default.moveItem(at: localURL, to: destination)
        print("文件", filename, "下载成功")

        // 解压缩
        let unzipDirectory = URL(filePath: FileManager.default.currentDirectoryPath).appending(component: "Resources").appending(component: filename)
        try Zip.unzipFile(destination, destination: unzipDirectory, overwrite: false, password: nil)
        try await upload(with: unzipDirectory)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.removeItem(at: unzipDirectory)

        // 结束重新写入ids
        try JSONSerialization.data(withJSONObject: courseIds.filter { $0 != id }).write(to: URL(filePath: FileManager.default.currentDirectoryPath).appending(component: "ids.json"))
        courseIds = try JSONSerialization.jsonObject(with: try Data(contentsOf: URL(filePath: FileManager.default.currentDirectoryPath).appending(component: "ids.json"))) as? [Int] ?? []
    }
} catch {
    print(error.localizedDescription)
}


func upload(with url: URL) async throws {
    let folder = url.path

    // 获取所有文件，并且遍历
    let files = (try FileManager.default.contentsOfDirectory(atPath: folder)).filter { $0.contains("coursesubject") }
    for filename in files {

        print("执行操作文件", filename)

        let filePath = folder + "/" + filename
        let fileJSON = JSON(parseJSON: try String(contentsOfFile: filePath))
        var questions: [(String, String)] = []

        // 遍历所有题目
        for json in fileJSON.arrayValue {
            switch json["isubjecttype"].intValue {
            case 0, 6: // 选择题
                var title = json["ctitle"].stringValue
                var question = json["cquestion"].stringValue
                if title.contains("A") && !question.contains("A") {
                    if question.isEmpty {
                        let temp = title
                        title = String(temp.split(separator: "A").first!)
                        question = temp.replacingOccurrences(of: title, with: "")
                    } else {
                        (title,question) = (question, title)
                    }
                }
                if title.count < 6 {
                    title = String(question.split(separator: "A.").first ?? "")
                }
                question = question
                    .replacingOccurrences(of: "A、", with: "A.")
                    .replacingOccurrences(of: "B、", with: "B.")
                    .replacingOccurrences(of: "C、", with: "C.")
                    .replacingOccurrences(of: "D、", with: "D.")
                    .replacingOccurrences(of: "E、", with: "E.")
                    .replacingOccurrences(of: "F、", with: "F.")
                    .replacingOccurrences(of: "G、", with: "G.")
                    .replacingOccurrences(of: "H、", with: "H.")
                let answerNumber = json["canswer"].stringValue + "."
                let answer = String(question.split(separator: "\r\n").first(where: { $0.contains(answerNumber) }) ?? "").replacingOccurrences(of: answerNumber, with: "")
                questions.append((title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil), answer.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)))
            case 1: // 多选题
                let title = json["ctitle"].stringValue
                let answerNumbers = Array(json["canswer"].stringValue).map { String($0) }
                let answer = json["cquestion"].stringValue.split(separator: "\r\n").filter { answerNumbers.contains(String($0.prefix(1))) }.map { sub in
                    var a = String(sub)
                    return a.slice(at: 2)
                }.joined(separator: "；")
                questions.append((title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil), answer.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)))
            case 2: // 判断题
                let title = json["ctitle"].stringValue
                let answer = json["canswer"].stringValue
                questions.append((title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil), answer.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)))
            case 3: // 问答
                let title = json["ctitle"].stringValue
                let answer = json["description"].stringValue
                questions.append((title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil), answer.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)))
            case 4: // 问答
                let title = json["ctitle"].stringValue
                let answer = json["description"].stringValue
                questions.append((title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil), answer.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)))
            case 5: // 填空
                let title = json["ctitle"].stringValue
                let answer = json["description"].stringValue
                questions.append((title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil), answer.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)))
            default:
                print("未知题目类型")
            }
        }

        questions.forEach {
            print("题目：", $0.0)
            print("答案：", $0.1)
            print("-----")
        }

        print("开始录入")

        for (question, answer) in questions {
            do {
                try await Task.sleep(for: .seconds(1))
                guard !question.isEmpty && !answer.isEmpty && question.count > 5 else {
                    continue
                }
                let body = """
                {
                  "question_json": "{\\"text\\": \\"\(question.trimmingCharacters(in: .whitespacesAndNewlines))\\"}",
                  "answer_json": "{\\"text\\":\\"\(answer.trimmingCharacters(in: .whitespacesAndNewlines))\\"}"
                }
                """
                var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/question")!)
                request.httpMethod = "POST"
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJleHAiOjE2OTM1MzYyOTIwMDAsImlkIjoiMTIzIn0._4qj2jpALIZ2HAXShfKkNf4B2laZxRxUtgsOYrvRZjI", forHTTPHeaderField: "authorization")
                request.httpBody = body.data(using: .utf8)
                let (_, response) = try await URLSession.shared.data(for: request)
                print((response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                print(error)
            }
        }
    }
}
