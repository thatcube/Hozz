import Foundation
func fmt(_ d: Date, _ tz: TimeZone) -> String {
    let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"; return f.string(from: d)
}
print("=== Santiago 2025/2026 still transitions at local midnight? ===")
let tz = TimeZone(identifier: "America/Santiago")!
var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
var p = cal.date(from: DateComponents(year: 2025, month: 1, day: 1))!
let stop = cal.date(from: DateComponents(year: 2027, month: 1, day: 1))!
while let n = tz.nextDaylightSavingTimeTransition(after: p), n < stop {
    print("  transition at \(fmt(n, tz))  startOfDay=\(fmt(cal.startOfDay(for: n), tz))")
    p = n
}

print("\n=== Does nextDaylightSavingTimeTransition report NON-DST offset changes? ===")
// Istanbul permanently moved +02 -> +03 on 2016-09-07 and has had no DST since.
let ist = TimeZone(identifier: "Europe/Istanbul")!
var icc = Calendar(identifier: .gregorian); icc.timeZone = ist
var q = icc.date(from: DateComponents(year: 2016, month: 1, day: 1))!
let istop = icc.date(from: DateComponents(year: 2020, month: 1, day: 1))!
var found: [Date] = []
while let n = ist.nextDaylightSavingTimeTransition(after: q), n < istop { found.append(n); q = n }
print("  Istanbul transitions found 2016-2020: \(found.map { fmt($0, ist) })")
print("  offset 2016-06-01: \(ist.secondsFromGMT(for: icc.date(from: DateComponents(year:2016,month:6,day:1))!))")
print("  offset 2017-06-01: \(ist.secondsFromGMT(for: icc.date(from: DateComponents(year:2017,month:6,day:1))!))")

// Simulate LocalDayExpression segments for Istanbul over 2016-01-01 .. 2018-01-01
struct Seg { let until: Date; let off: Int }
func segments(_ tz: TimeZone, _ start: Date, _ end: Date) -> ([Seg], Int) {
    var segs: [Seg] = []; var cursor = start; var off = tz.secondsFromGMT(for: start); var g = 0
    while let next = tz.nextDaylightSavingTimeTransition(after: cursor), next < end, g < 512 {
        segs.append(Seg(until: next, off: off)); off = tz.secondsFromGMT(for: next); cursor = next; g += 1
    }
    return (segs, off)
}
let s = icc.date(from: DateComponents(year:2016,month:1,day:1))!
let e = icc.date(from: DateComponents(year:2018,month:1,day:1))!
let (segs, finalOff) = segments(ist, s, e)
print("  segments: \(segs.map { (fmt($0.until, ist), $0.off) }), final=\(finalOff)")
// check a 2017 timestamp: 00:30 local on 2017-06-15
let bias = 62_135_596_800
func sqlDay(_ d: Date) -> Int {
    var off = finalOff
    for sg in segs where d < sg.until { off = sg.off; break }
    return (Int(d.timeIntervalSince1970.rounded(.down)) + off + bias) / 86400
}
func calDay(_ d: Date) -> String { let f = DateFormatter(); f.timeZone = ist; f.dateFormat = "yyyy-MM-dd"; return f.string(from: d) }
for hh in [0, 1] {
    let d = icc.date(from: DateComponents(year:2017,month:6,day:15,hour:hh,minute:30))!
    let base = icc.date(from: DateComponents(year:2017,month:6,day:15))!
    let baseDay = (Int(base.timeIntervalSince1970.rounded(.down)) + ist.secondsFromGMT(for: base) + bias) / 86400
    print("  local \(fmt(d, ist)) -> SQL day \(sqlDay(d)); true local date \(calDay(d)) (day# \(baseDay))")
}
