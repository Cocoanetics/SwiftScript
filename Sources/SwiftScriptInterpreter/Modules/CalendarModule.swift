import Foundation

/// Calendar support — opaque `Calendar`, opaque `DateComponents`, and a
/// hand-rolled `Calendar.Component` type whose static members each carry
/// the matching `Foundation.Calendar.Component` as `Value.opaque`. Scripts
/// can write the explicit form `Calendar.Component.year`; implicit-member
/// shorthand (`.year` at a method-call site) requires bidirectional type
/// inference we don't have, so it's not yet supported.
///
/// What's covered intentionally tightly:
///   - `Calendar.current` — opaque carrier of the user's calendar
///   - `Calendar.Component.{year, month, day, hour, minute, second,
///      weekday, weekOfYear, dayOfYear, era, nanosecond, weekOfMonth}`
///   - `cal.component(_:from:) -> Int`
///   - `cal.date(byAdding:value:to:) -> Date?`
///   - `DateComponents.{year, month, day, hour, minute, second}` getters
///   - `cal.dateComponents([components], from:)` — the array-of-Component
///     overload (we don't model `Set<Calendar.Component>` literals).
///   - `cal.date(from: DateComponents) -> Date?` and the matching
///     keyword-only initializer for `DateComponents`.
struct CalendarModule: BuiltinModule {
    let name = "Calendar"

    func register(into i: Interpreter) {
        registerCalendarStatic(into: i)
        registerCalendarComponentStatic(into: i)
        registerCalendarMethods(into: i)
        registerDateComponents(into: i)
    }

    private func registerCalendarStatic(into i: Interpreter) {
        i.bridges["static let Calendar.current"] =
            .staticValue(.opaque(typeName: "Calendar", value: Calendar.current))
    }

    private func registerCalendarComponentStatic(into i: Interpreter) {
        let cases: [(String, Calendar.Component)] = [
            ("era", .era),
            ("year", .year),
            ("month", .month),
            ("day", .day),
            ("hour", .hour),
            ("minute", .minute),
            ("second", .second),
            ("nanosecond", .nanosecond),
            ("weekday", .weekday),
            ("weekdayOrdinal", .weekdayOrdinal),
            ("weekOfMonth", .weekOfMonth),
            ("weekOfYear", .weekOfYear),
            ("yearForWeekOfYear", .yearForWeekOfYear),
            ("quarter", .quarter),
        ]
        for (name, value) in cases {
            i.bridges["static let Calendar.Component.\(name)"] =
                .staticValue(.opaque(typeName: "Calendar.Component", value: value))
        }
    }

    private func registerCalendarMethods(into i: Interpreter) {
        i.bridges["func Calendar.component()"] = .method { receiver, args in
            guard args.count == 2,
                  case .opaque(_, let cal) = receiver, let cal = cal as? Calendar,
                  case .opaque(_, let comp) = args[0], let comp = comp as? Calendar.Component,
                  case .opaque(_, let date) = args[1], let date = date as? Date
            else {
                throw RuntimeError.invalid(
                    "Calendar.component(_:from:): expected (Calendar.Component, Date)"
                )
            }
            return .int(cal.component(comp, from: date))
        }
        i.bridges["func Calendar.date()"] = .method { receiver, args in
            guard case .opaque(_, let cal) = receiver, let cal = cal as? Calendar
            else { throw RuntimeError.invalid("Calendar.date: receiver must be Calendar") }
            // Two overloads: `date(byAdding:value:to:)` (3 args, no labels
            // here) and `date(from: DateComponents)` (1 arg). Dispatch on
            // arg count.
            if args.count == 3 {
                guard case .opaque(_, let comp) = args[0], let comp = comp as? Calendar.Component,
                      case .int(let v) = args[1],
                      case .opaque(_, let date) = args[2], let date = date as? Date
                else {
                    throw RuntimeError.invalid(
                        "Calendar.date(byAdding:value:to:): expected (Calendar.Component, Int, Date)"
                    )
                }
                if let result = cal.date(byAdding: comp, value: v, to: date) {
                    return .optional(.opaque(typeName: "Date", value: result))
                }
                return .optional(nil)
            }
            if args.count == 1 {
                guard case .opaque(_, let comps) = args[0], let comps = comps as? DateComponents
                else { throw RuntimeError.invalid("Calendar.date(from:): expected DateComponents") }
                if let result = cal.date(from: comps) {
                    return .optional(.opaque(typeName: "Date", value: result))
                }
                return .optional(nil)
            }
            throw RuntimeError.invalid("Calendar.date: 1 or 3 arguments expected, got \(args.count)")
        }
        i.bridges["func Calendar.dateComponents()"] = .method { receiver, args in
            guard args.count == 2,
                  case .opaque(_, let cal) = receiver, let cal = cal as? Calendar,
                  case .array(let compValues) = args[0],
                  case .opaque(_, let date) = args[1], let date = date as? Date
            else {
                throw RuntimeError.invalid(
                    "Calendar.dateComponents(_:from:): expected ([Calendar.Component], Date)"
                )
            }
            var set: Set<Calendar.Component> = []
            for v in compValues {
                guard case .opaque(_, let cv) = v, let cv = cv as? Calendar.Component else {
                    throw RuntimeError.invalid(
                        "Calendar.dateComponents: array element must be Calendar.Component"
                    )
                }
                set.insert(cv)
            }
            return .opaque(typeName: "DateComponents", value: cal.dateComponents(set, from: date))
        }
    }

    private func registerDateComponents(into i: Interpreter) {
        // Read-only Int? getters for the most-asked DateComponents fields.
        let fields: [(String, (DateComponents) -> Int?)] = [
            ("era",            \.era),
            ("year",           \.year),
            ("month",          \.month),
            ("day",            \.day),
            ("hour",           \.hour),
            ("minute",         \.minute),
            ("second",         \.second),
            ("nanosecond",     \.nanosecond),
            ("weekday",        \.weekday),
            ("weekdayOrdinal", \.weekdayOrdinal),
            ("weekOfMonth",    \.weekOfMonth),
            ("weekOfYear",     \.weekOfYear),
            ("quarter",        \.quarter),
        ]
        for (name, get) in fields {
            i.bridges["var DateComponents.\(name)"] = .computed { recv in
                guard case .opaque(_, let any) = recv, let dc = any as? DateComponents else {
                    throw RuntimeError.invalid("DateComponents.\(name): receiver must be DateComponents")
                }
                if let v = get(dc) { return .optional(.int(v)) }
                return .optional(nil)
            }
        }

        // `DateComponents(year:month:day:hour:minute:second:)` — labels
        // are all optional in real Swift, but for the interpreter we model
        // the exact label-set the user wrote. The most common shapes:
        // {year,month,day} and {year,month,day,hour,minute,second}.
        let registerInit: ([String]) -> Void = { labels in
            let key = i.bridgeKey(forInit: "DateComponents", labels: labels.map { Optional($0) })
            i.bridges[key] = .`init` { args in
                var dc = DateComponents()
                for (label, value) in zip(labels, args) {
                    guard case .int(let v) = value else {
                        throw RuntimeError.invalid("DateComponents.\(label): must be Int")
                    }
                    switch label {
                    case "year":    dc.year = v
                    case "month":   dc.month = v
                    case "day":     dc.day = v
                    case "hour":    dc.hour = v
                    case "minute":  dc.minute = v
                    case "second":  dc.second = v
                    default:
                        throw RuntimeError.invalid("DateComponents: unsupported label '\(label)'")
                    }
                }
                return .opaque(typeName: "DateComponents", value: dc)
            }
        }
        registerInit([])
        registerInit(["year"])
        registerInit(["year", "month"])
        registerInit(["year", "month", "day"])
        registerInit(["year", "month", "day", "hour"])
        registerInit(["year", "month", "day", "hour", "minute"])
        registerInit(["year", "month", "day", "hour", "minute", "second"])
    }
}
