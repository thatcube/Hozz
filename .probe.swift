import Foundation

func iso(_ d: Date, _ tz: TimeZone) -> String {
    var c = Calendar(identifier: .gregorian); c.timeZone = tz
    let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
    return f.string(from: d)
}

print("=== A: covering() day drift in midnight-DST zones ===")
for id in ["America/Santiago", "America/Havana", "America/Asuncion", "Asia/Tehran", "America/Sao_Paulo"] {
    guard let tz = TimeZone(identifier: id) else { continue }
    var cal = Calendar(identifier: .gregorian); cal.timeZone = tz; cal.firstWeekday = 1
    // find a spring-forward transition at local midnight in 2016..2019
    var probe = cal.date(from: DateComponents(year: 2016, month: 1, day: 1))!
    let stop = cal.date(from: DateComponents(year: 2020, month: 1, day: 1))!
    while let next = tz.nextDaylightSavingTimeTransition(after: probe), next < stop {
        let before = tz.secondsFromGMT(for: next.addingTimeInterval(-1))
        let after = tz.secondsFromGMT(for: next)
        if after > before {
            // is local wall clock at transition exactly 00:00 -> so midnight missing?
            let sod = cal.startOfDay(for: next)
            let comps = cal.dateComponents([.hour, .minute], from: sod)
            if comps.hour != 0 {
                print("\(id): transition \(iso(next, tz)); startOfDay is \(iso(sod, tz))")
                // now simulate covering() from 5 days before
                let start = cal.date(byAdding: .day, value: -3, to: sod)!
                var cursor = cal.startOfDay(for: start)
                for i in 0..<7 {
                    let nxt = cal.date(byAdding: .day, value: 1, to: cursor)!
                    let real = cal.startOfDay(for: cursor)
                    let flag = (real == cursor) ? "" : "   <-- MISALIGNED, startOfDay=\(iso(real, tz))"
                    print("   col\(i) start \(iso(cursor, tz))\(flag)")
                    cursor = nxt
                }
                break
            }
        }
        probe = next
    }
}
