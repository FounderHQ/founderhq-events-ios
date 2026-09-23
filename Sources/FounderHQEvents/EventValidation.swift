import Foundation

func isEventUUID(_ value: String) -> Bool {
    value.range(
        of: #"\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
}

/// Shared by hook validation and TTL pruning, including timestamps without fractions.
func parseEventTimestamp(_ value: String) -> Date? {
    guard value.range(
        of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\z"#,
        options: .regularExpression
    ) != nil else { return nil }
    let bytes = Array(value.utf8)
    func number(_ start: Int, _ length: Int) -> Int {
        bytes[start..<(start + length)].reduce(0) { $0 * 10 + Int($1 - 48) }
    }
    let year = number(0, 4), month = number(5, 2), day = number(8, 2)
    let hour = number(11, 2), minute = number(14, 2), second = number(17, 2)
    guard year >= 1, (1...12).contains(month), (1...31).contains(day),
          hour <= 23, minute <= 59, second <= 59 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(year: year, month: month, day: day,
                                    hour: hour, minute: minute, second: second)
    guard let local = calendar.date(from: components) else { return nil }
    let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: local)
    guard actual == components else { return nil }
    let zoneStart = bytes.last == 90 ? bytes.count - 1 : bytes.count - 6
    var offset = 0
    if bytes[zoneStart] != 90 {
        let zoneHour = number(zoneStart + 1, 2), zoneMinute = number(zoneStart + 4, 2)
        guard zoneHour <= 23, zoneMinute <= 59 else { return nil }
        offset = (zoneHour * 3600 + zoneMinute * 60) * (bytes[zoneStart] == 45 ? -1 : 1)
    }
    let fraction = zoneStart > 19
        ? Double("0" + String(decoding: bytes[19..<zoneStart], as: UTF8.self)) ?? 0
        : 0
    return local.addingTimeInterval(fraction - Double(offset))
}
