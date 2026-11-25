import XCTest

final class PlannerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCreateGoalTaskScheduleAndComplete() throws {
        let app = XCUIApplication(); app.launch()
        for name in ["目標", "計畫", "日記", "人脈"] { XCTAssertTrue(app.tabBars.buttons[name].exists) }
        XCTAssertTrue(app.buttons["domain_spiritual"].exists)
        XCTAssertTrue(app.buttons["domain_work"].exists)
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "Goals-home"; home.lifetime = .keepAlways; add(home)
        app.buttons["domain_intellectual"].tap()
        app.buttons["新增目標"].tap()
        let title = "測試日文目標 \(UUID().uuidString.prefix(4))"
        app.textFields["goalTitle"].tap(); app.textFields["goalTitle"].typeText(title)
        app.buttons["saveGoal"].tap()
        app.staticTexts[title].tap()
        app.buttons["addGoalTask"].tap()
        let task = "練習自我介紹"
        app.textFields["taskTitle"].tap(); app.textFields["taskTitle"].typeText(task)
        app.buttons["saveTask"].tap()
        XCTAssertTrue(app.staticTexts[task].waitForExistence(timeout: 5))
        app.buttons["安排日期：\(task)"].tap()
        app.buttons["schedule_今天"].tap()
        app.buttons["完成：\(task)"].tap()
        XCTAssertTrue(app.staticTexts["任務完成 1/1"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Goal-task-completed"; attachment.lifetime = .keepAlways; add(attachment)
        app.tabBars.buttons["計畫"].tap()
        XCTAssertTrue(app.buttons["切換日週月年"].exists)
        app.tabBars.buttons["日記"].tap()
        XCTAssertTrue(app.buttons["寫日記"].exists)
        app.tabBars.buttons["人脈"].tap()
        XCTAssertTrue(app.buttons["新增聯絡人"].exists)
    }

    @MainActor
    func testUnplannedBulkAndContinuousScheduling() throws {
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["計畫"].tap()
        app.buttons["filter_待安排"].tap()
        let suffix = String(UUID().uuidString.prefix(4))
        for name in ["整理資料", "準備報告"] {
            app.buttons["新增任務"].tap()
            app.textFields["taskTitle"].tap(); app.textFields["taskTitle"].typeText(name + suffix)
            app.buttons["saveTask"].tap()
        }
        app.buttons["選取"].tap()
        app.buttons["選取：整理資料\(suffix)"].tap()
        app.buttons["選取：準備報告\(suffix)"].tap()
        app.buttons["安排日期"].tap()
        app.buttons["schedule_下週"].tap()
        XCTAssertFalse(app.staticTexts["整理資料\(suffix)"].exists)
        app.buttons["filter_全部"].tap()
        app.buttons["安排日期：整理資料\(suffix)"].tap()
        app.buttons["放回待安排"].tap()
        app.buttons["filter_待安排"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "連續安排這")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["正在安排"].exists)
        app.buttons["今天"].tap()
        XCTAssertTrue(app.staticTexts["這一輪安排完成"].waitForExistence(timeout: 5))
        app.buttons["復原上一項"].tap()
        XCTAssertTrue(app.staticTexts["整理資料\(suffix)"].exists)
        app.buttons["完成"].tap()
    }
}
