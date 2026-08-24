import Foundation
func fmt(_ d: Date, _ tz: TimeZone) -> String {
    let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: d)
}
let tz = TimeZone(identifier: "America/Santiago")!
var cal = Calendar(identifier: .gregorian); cal.timeZone = tz; cal.firstWeekday = 1
let now = cal.date(from: DateComponents(year: 2025, month: 9, day: 20, hour: 14))!

// Real trailing(30, .day) via the shipped code
let plan = TimeBucketPlan.trailing(30, granularity: .day, endingAt: now, calendar: cal)
print("columns: \(plan.columns.count)")
var bad = 0
for c in plan.columns {
    let sod = cal.startOfDay(for: c.start)
    if sod != c.start { bad += 1 }
}
print("misaligned columns: \(bad)")
for c in plan.columns.suffix(18) {
    let sod = cal.startOfDay(for: c.start)
    print("  idx \(c.index) start \(fmt(c.start, tz)) end \(fmt(c.end, tz)) \(sod == c.start ? "" : "<-- NOT startOfDay (\(fmt(sod, tz)))")")
}

// Where does a 00:30-local sample on 2025-09-15 land?
let s = cal.date(from: DateComponents(year: 2025, month: 9, day: 15, hour: 0, minute: 30))!
let expr = LocalDayExpression(timeZone: tz, from: plan.span!.start, to: plan.span!.end)
print("\nsample local \(fmt(s, tz))")
for c in plan.columns where c.start <= s && s < c.end {
    print("  falls in column starting \(fmt(c.start, tz)) — a column labelled \(fmt(c.start, tz).prefix(10))")
}
print("  SQL local-day number = \(expr.day(for: s, timeZone: tz))")
let mid = cal.date(from: DateComponents(year: 2025, month: 9, day: 15))!
print("  day# of 2025-09-15 midnight = \(expr.day(for: mid, timeZone: tz))")
let mid14 = cal.date(from: DateComponents(year: 2025, month: 9, day: 14))!
print("  day# of 2025-09-14 midnight = \(expr.day(for: mid14, timeZone: tz))")
