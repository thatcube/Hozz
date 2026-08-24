import Foundation

/// The words an overview row and its heading use.
///
/// These live here rather than in the view because they are claims about the
/// data — how many days a total came from, whether a number is current, what
/// the figure beside it is measured in — and a claim about the data is exactly
/// the kind of thing that should be pinned by a test. Every wrong-word bug this
/// dashboard has had was a sentence no test could reach.
public enum OverviewNarration {
    /// The heading over a group of rows.
    ///
    /// When no row reaches the chosen range, the range is not used as the
    /// heading. "Past thirty days — none of these reach it" contradicts itself
    /// inside a single sentence, and a heading that has to be walked back by
    /// its own subordinate clause is worse than one that was never claimed.
    public static func heading(
        range: ChartRange,
        staleRows: Int,
        totalRows: Int
    ) -> String {
        guard staleRows > 0 else { return range.windowTitle }
        if staleRows >= totalRows {
            return "Nothing in \(range.windowNoun) has reached this computer "
                + "yet — each row shows the most recent stretch that has."
        }
        return "\(range.windowTitle) — \(staleRows) of \(totalRows) have not "
            + "reached it yet and show the most recent stretch that has."
    }

    /// What is known about how completely one type has been read, in full.
    ///
    /// The row caption has one line and must be terse; this is for the places
    /// with room to say the whole thing — the type's own screen, and the
    /// answers an assistant reads. Both used to explain the sweep in general
    /// terms and hedge, which is not the same as being accurate: "the newest
    /// days often arrive last" is true of an unfinished type and misleading
    /// about a finished one, and it was shown for both because nothing knew
    /// the difference.
    ///
    /// `day` is injected so a locale cannot decide half the sentence.
    public static func completeness(
        _ standing: TypeCoverageStanding,
        latest: Date?,
        day: (Date) -> String
    ) -> String {
        let newest = latest.map(day)

        switch standing {
        case .complete:
            guard let newest else {
                return "Your phone has finished reading this type: everything "
                    + "Health holds for it is here."
            }
            return "Your phone has finished reading this type, so \(newest) "
                + "really is your most recent record — not just the most "
                + "recent one that has arrived."

        case .incomplete(let report):
            if let from = report.primedFrom, let through = report.primedThrough {
                return "Your phone has filled in \(day(from)) to \(day(through)) "
                    + "directly, and is still working back through everything "
                    + "older. Those two stretches do not meet yet, so there is "
                    + "a gap in the middle that is not a gap in your history."
            }
            if report.state == .authorizationIndeterminate {
                return "Your phone finished reading this type and Health "
                    + "returned nothing at all. Health answers the same way "
                    + "whether you have no records of it or Hozz was never "
                    + "granted it, so this cannot tell you which."
            }
            guard let newest else {
                return "Your phone is still reading this type, so what is here "
                    + "is not all of it yet."
            }
            return "Your phone is still reading this type. It arrives in the "
                + "order Health stored it rather than in date order, so "
                + "\(newest) is the newest record that has arrived and not "
                + "necessarily your newest."

        case .untold:
            guard let newest else {
                return "Your phone has not said whether it has finished "
                    + "reading this type, so what is here may not be all of it."
            }
            return "Your phone has not said whether it has finished reading "
                + "this type. \(newest) is the newest record that has arrived, "
                + "which may or may not be your newest."
        }
    }
}

extension ChartRange {
    /// The range as a heading.
    public var windowTitle: String {
        switch self {
        case .week: "Past seven days"
        case .month: "Past thirty days"
        case .year: "Past year"
        case .all: "Everything held"
        }
    }

    /// The range as something a sentence can contain.
    public var windowNoun: String {
        switch self {
        case .week: "the past seven days"
        case .month: "the past thirty days"
        case .year: "the past year"
        case .all: "the range held"
        }
    }
}

extension IngestStore.MetricSnapshot {
    /// What goes under the number, or nothing.
    ///
    /// Only a unit belongs in this slot. A type with no unit — a count of
    /// steps, a count of hours stood — gets nothing, because the alternative
    /// tried and discarded was to print the aggregation there, which put the
    /// word "Total" where "kcal" sits one row above. That is not a unit, it is
    /// already in the caption, and in the one place on the row reserved for
    /// saying what the number is measured in it says something else.
    public var unitLabel: String? {
        let label = series.displayUnit.label
        return label.isEmpty ? nil : label
    }

    /// The stretch the drawn series actually covers.
    public var shownWindow: (start: Date, end: Date)? {
        guard
            let first = series.columns.first,
            let last = series.columns.last
        else { return nil }
        return (first.start, last.end)
    }

    /// Whether every record Health holds inside the drawn window is here.
    ///
    /// True in exactly two cases, and both are things the phone said rather
    /// than things the receiver worked out. A finished sweep means the whole
    /// archive is here, so any window inside it is. A primed window is a
    /// genuine density claim about the stretch a dated query filled, so a
    /// drawn window inside that stretch is complete even while the sweep is
    /// still years back.
    ///
    /// With one exception, which matters most for the types people look at
    /// first. A dated read carries the *samples* in its window, and a
    /// high-frequency type's sample is an aggregate standing for hundreds of
    /// underlying readings that the prime does not fetch. The chart above this
    /// row is drawn from those readings. So for a series that has aggregated
    /// samples, a primed window promises the containers and not the contents,
    /// and a row that dropped its qualifier on the strength of it would read
    /// as complete while most of its readings were still weeks behind in the
    /// sweep. A finished sweep carries the readings too, so it is unaffected.
    ///
    /// False for everything else, including a type nothing has been said
    /// about. That is the point: a receiver that has been told nothing knows
    /// nothing, and the absence of a report is not a report of completeness.
    public var shownWindowIsFullyHeld: Bool {
        if standing.licensesLatestDate {
            return true
        }
        guard
            let window = standing.primedWindow,
            let shown = shownWindow,
            !series.hasAggregatedSamples
        else {
            return false
        }
        return shown.start >= window.from && shown.end <= window.through
    }

    /// What the number is, and — when it is not from the range asked for —
    /// which window it is from instead.
    ///
    /// `monthName` is injected so the sentence can be checked without a
    /// locale deciding half of it.
    ///
    /// The leading clause always carries the honesty, because this caption is
    /// drawn on one line and truncates from the right. A qualifier at the end
    /// is a qualifier that disappears on a narrow window, which is the same as
    /// not writing it.
    public func rowCaption(monthName: (Date) -> String) -> String {
        if series.hasMixedUnits {
            return "Mixed units — not combined"
        }
        if series.headline == nil {
            guard let latest = latestOverall else { return "No values yet" }
            // Even here the date is a claim. "last Dec 2022" says the person
            // has nothing since; only a finished sweep can support that.
            return standing.licensesLatestDate
                ? "Nothing yet · last \(monthName(latest))"
                : "Nothing yet · received to \(monthName(latest))"
        }

        var text = series.measure.kind.noun.lowercased()
        if !series.coverage.isEveryDay {
            text += " · \(series.coverage.daysWithData)/\(series.coverage.dayCount) days"
        }

        guard let latest = latestOverall, isFromEarlierWindow else {
            // A window that is not stale still gets a leading qualifier when
            // the records in it are not all here. Silence in this slot reads
            // as a complete figure, and during a first sweep almost none of
            // them are — the days count beside it does not say so either,
            // because "2/30 days" is equally readable as two days of cycling.
            guard let prefix = Self.arrivalPrefix(for: standing),
                  !shownWindowIsFullyHeld else {
                return text
            }
            return "\(prefix) · \(text)"
        }

        // "received to", never "as of", unless the phone has said the sweep
        // for this type ran out of records.
        //
        // The receiver used to be told only that batches arrived, never that a
        // type was finished, so it could not distinguish a person who stopped
        // walking in Jan 2023 from a sweep that had only carried step count as
        // far as Jan 2023. It said "as of" anyway, which picks the first
        // reading and states it as fact. On Brandon's archive the first
        // reading was false and the second true, and the row told a bedbound
        // person they had not walked in three years.
        //
        // Now the phone says which it is, so the flattering wording is
        // available exactly when it is earned and never otherwise.
        //
        // Coverage belongs here too and used to be dropped. A row that has
        // fallen back to its own last stretch is the likeliest of all to be a
        // couple of days of data wearing a thirty-day total's clothes.
        let lead = standing.licensesLatestDate ? "as of" : "received to"
        return "\(lead) \(monthName(latest)) · \(text)"
    }

    /// The words that go in front of a figure whose records are not all here.
    ///
    /// A type the phone has reported on is genuinely still being read, which
    /// is worth saying plainly — it is coming. A type nothing has been said
    /// about might be finished, might not, and this receiver has no way to
    /// tell, so it claims neither.
    private static func arrivalPrefix(for standing: TypeCoverageStanding) -> String? {
        switch standing {
        case .complete: nil
        case .incomplete: "still arriving"
        case .untold: "may be incomplete"
        }
    }
}
