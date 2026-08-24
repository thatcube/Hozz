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

    /// What the number is, and — when it is not from the range asked for —
    /// which window it is from instead.
    ///
    /// `monthName` is injected so the sentence can be checked without a
    /// locale deciding half of it.
    public func rowCaption(monthName: (Date) -> String) -> String {
        if series.hasMixedUnits {
            return "Mixed units — not combined"
        }
        if series.headline == nil {
            guard let latest = latestOverall else { return "No values yet" }
            return "Nothing yet · last \(monthName(latest))"
        }

        var text = series.measure.kind.noun.lowercased()
        if !series.coverage.isEveryDay {
            text += " · \(series.coverage.daysWithData)/\(series.coverage.dayCount) days"
        }

        guard isFromEarlierWindow, let latest = latestOverall else {
            return text
        }
        // "received to", never "as of". The receiver is told when records
        // arrive and never told that a type is finished, so it cannot
        // distinguish a person who stopped walking in Jan 2023 from a sweep
        // that has only carried step count as far as Jan 2023. It said "as of"
        // anyway, which picks the first reading and states it as fact.
        //
        // On Brandon's archive the first reading was false and the second true,
        // and the row told a bedbound person they had not walked in three
        // years. Saying what actually happened — this much has arrived — is
        // true whichever it is, and is the whole of the first rule.
        //
        // Coverage belongs here too and used to be dropped. A row that has
        // fallen back to its own last stretch is the likeliest of all to be a
        // couple of days of data wearing a thirty-day total's clothes.
        return "received to \(monthName(latest)) · \(text)"
    }
}
