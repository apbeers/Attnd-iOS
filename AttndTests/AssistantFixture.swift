// AssistantFixture.swift
// AttndTests
//
// The event assistant's fixture (assistant spec §9; Android's `unit/AssistantFixture.kt`):
// `PlannerFixture` plus the planner test's "Plan my Saturday around live music and BBQ" plan,
// made at Sat 10:00 AM with the fixture's likes (101, 114):
// 10:00 111 · 11:00 109 · 12:00 lunch · 13:00 102 · 15:00 103 · 17:00 105 · 18:15 113 · 19:00 101 · 21:00 104.

import Foundation
@testable import Attnd

enum AssistantFixture {
    static let likes = LikeSet(scheduleItems: PlannerFixture.heartedItems)
    static let musicAndBbq = PlanPreferences(likedTags: ["live music", "bbq"], includeMeals: true)
    static let plan: Plan = Planner(bundle: PlannerFixture.bundle, preferences: musicAndBbq, heartedItems: PlannerFixture.heartedItems)
        .plan(from: PlannerFixture.now, request: "Plan my Saturday around live music and BBQ")
    static let enUS = Locale(identifier: "en_US")

    /// At the Main Stage (location 1).
    static let atMainStage = PlannerFixture.bundle.location(1)!.coordinate!

    static func ctx(likes: LikeSet = AssistantFixture.likes, plan: Plan? = AssistantFixture.plan, user: Coordinate? = nil) -> RouterContext {
        RouterContext(bundle: PlannerFixture.bundle, likes: likes, plan: plan, now: PlannerFixture.now, user: user)
    }

    /// "10:00 111", "12:00 lunch", … in the event's zone.
    static func clock(_ plan: Plan) -> [String] {
        let calendar = PlanCalendar.calendar(PlannerFixture.chicago)
        return plan.days.flatMap { day in
            day.entries.map { entry -> String in
                let c = calendar.dateComponents([.hour, .minute], from: entry.start)
                let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
                switch entry {
                case .item(let item): return "\(time) \(item.itemId)"
                case .meal(let meal): return "\(time) \(meal.kind.rawValue)"
                }
            }
        }
    }
}
