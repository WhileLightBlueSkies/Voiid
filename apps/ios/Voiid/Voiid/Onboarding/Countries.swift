//
//  Countries.swift
//  Voiid
//
//  Full country list for the phone-number selector. Names + flags are derived from the
//  device's locale data (always localized + complete); dial codes come from a static map
//  keyed by ISO 3166-1 alpha-2 region code. India is the default.
//

import Foundation

struct Country: Identifiable, Hashable {
    let id: String          // ISO region code, e.g. "IN"
    let name: String        // localized country name
    let dialCode: String    // e.g. "+91"
    let flag: String        // emoji flag

    /// Plausible national-number length, used to enable Continue and to bound autofill
    /// normalisation.
    ///
    /// NOT A VALIDITY CHECK. Several countries have genuinely variable formats and carry a wide
    /// range rather than a wrong one; the SMS is the real validator. These exist so the button
    /// cannot be tapped on an obviously incomplete number, and so `normalise` knows when a
    /// leading dial code is spurious rather than part of the number.
    let minDigits: Int
    let maxDigits: Int

    static let `default` = CountryStore.all.first(where: { $0.id == "IN" }) ?? CountryStore.all[0]
}

enum CountryStore {
    /// All countries with a known dial code, sorted by localized name.
    static let all: [Country] = {
        Locale.Region.isoRegions
            .filter { $0.subRegions.isEmpty }                 // leaf regions (actual countries)
            .compactMap { region -> Country? in
                let code = region.identifier
                guard code.count == 2,
                      let dial = dialCodes[code],
                      let name = Locale.current.localizedString(forRegionCode: code)
                else { return nil }
                // Countries with no measured range fall back to 4...15 — E.164 permits at
                // most 15 digits including the dial code, so this rejects nothing legitimate
                // while still catching an empty or one-digit entry.
                let bounds = digitBounds[code] ?? (4, 15)
                return Country(id: code, name: name, dialCode: "+\(dial)", flag: flagEmoji(code),
                               minDigits: bounds.0, maxDigits: bounds.1)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// Regional-indicator flag emoji from a 2-letter region code.
    private static func flagEmoji(_ code: String) -> String {
        code.uppercased().unicodeScalars.reduce("") { acc, scalar in
            acc + String(UnicodeScalar(127397 + scalar.value)!)
        }
    }

    /// ISO alpha-2 → plausible national-number length (min, max), excluding the dial code.
    ///
    /// Sourced from the design reference's table. Only a gate for the Continue button and for
    /// autofill normalisation — see the note on `Country.minDigits`.
    private static let digitBounds: [String: (Int, Int)] = [
        "AD": (6, 9), "AE": (9, 9), "AF": (9, 9), "AG": (10, 10), "AI": (10, 10), "AL": (8, 9),
        "AM": (8, 8), "AO": (9, 9), "AR": (10, 11), "AS": (10, 10), "AT": (4, 13), "AU": (9, 9),
        "AW": (7, 7), "AX": (6, 12), "AZ": (9, 9), "BA": (8, 9), "BB": (10, 10), "BD": (6, 10),
        "BE": (8, 9), "BF": (8, 8), "BG": (7, 9), "BH": (8, 8), "BI": (8, 8), "BJ": (8, 8),
        "BL": (9, 9), "BM": (10, 10), "BN": (7, 7), "BO": (8, 8), "BQ": (7, 7), "BR": (10, 11),
        "BS": (10, 10), "BT": (7, 8), "BW": (7, 8), "BY": (9, 9), "BZ": (7, 7), "CA": (10, 10),
        "CD": (9, 9), "CF": (8, 8), "CG": (9, 9), "CH": (9, 9), "CI": (8, 10), "CK": (5, 5),
        "CL": (9, 9), "CM": (9, 9), "CN": (11, 11), "CO": (10, 10), "CR": (8, 8), "CU": (8, 8),
        "CV": (7, 7), "CW": (7, 8), "CY": (8, 8), "CZ": (9, 9), "DE": (6, 11), "DJ": (8, 8),
        "DK": (8, 8), "DM": (10, 10), "DO": (10, 10), "DZ": (9, 9), "EC": (9, 9), "EE": (7, 8),
        "EG": (10, 10), "ER": (7, 7), "ES": (9, 9), "ET": (9, 9), "FI": (6, 12), "FJ": (7, 7),
        "FK": (5, 5), "FM": (7, 7), "FO": (6, 6), "FR": (9, 9), "GA": (7, 8), "GB": (10, 10),
        "GD": (10, 10), "GE": (9, 9), "GF": (9, 9), "GG": (10, 10), "GH": (9, 9), "GI": (8, 8),
        "GL": (6, 6), "GM": (7, 7), "GN": (9, 9), "GP": (9, 9), "GQ": (9, 9), "GR": (10, 10),
        "GT": (8, 8), "GU": (10, 10), "GW": (9, 9), "GY": (7, 7), "HK": (8, 8), "HN": (8, 8),
        "HR": (8, 9), "HT": (8, 8), "HU": (9, 9), "ID": (9, 12), "IE": (9, 9), "IL": (9, 9),
        "IM": (10, 10), "IN": (10, 10), "IQ": (10, 10), "IR": (10, 10), "IS": (7, 9), "IT": (9, 11),
        "JE": (10, 10), "JM": (10, 10), "JO": (9, 9), "JP": (10, 10), "KE": (9, 9), "KG": (9, 9),
        "KH": (8, 9), "KI": (5, 8), "KM": (7, 7), "KN": (10, 10), "KP": (4, 13), "KR": (9, 10),
        "KW": (8, 8), "KY": (10, 10), "KZ": (10, 10), "LA": (8, 10), "LB": (7, 8), "LC": (10, 10),
        "LI": (7, 7), "LK": (9, 9), "LR": (8, 9), "LS": (8, 8), "LT": (8, 8), "LU": (9, 9),
        "LV": (8, 8), "LY": (9, 9), "MA": (9, 9), "MC": (8, 9), "MD": (8, 8), "ME": (8, 8),
        "MF": (9, 9), "MG": (9, 9), "MH": (7, 7), "MK": (8, 8), "ML": (8, 8), "MM": (8, 10),
        "MN": (8, 8), "MO": (8, 8), "MP": (10, 10), "MQ": (9, 9), "MR": (8, 8), "MS": (10, 10),
        "MT": (8, 8), "MU": (7, 8), "MV": (7, 7), "MW": (7, 9), "MX": (10, 10), "MY": (9, 10),
        "MZ": (9, 9), "NA": (9, 9), "NC": (6, 6), "NE": (8, 8), "NF": (6, 6), "NG": (8, 10),
        "NI": (8, 8), "NL": (9, 9), "NO": (8, 8), "NP": (10, 10), "NR": (7, 7), "NU": (4, 4),
        "NZ": (8, 10), "OM": (8, 8), "PA": (8, 8), "PE": (9, 9), "PF": (6, 6), "PG": (8, 8),
        "PH": (10, 10), "PK": (10, 10), "PL": (9, 9), "PM": (6, 6), "PR": (10, 10), "PS": (9, 9),
        "PT": (9, 9), "PW": (7, 7), "PY": (9, 9), "QA": (8, 8), "RE": (9, 9), "RO": (9, 9),
        "RS": (8, 9), "RU": (10, 10), "RW": (9, 9), "SA": (9, 9), "SB": (5, 7), "SC": (7, 7),
        "SD": (9, 9), "SE": (7, 13), "SG": (8, 8), "SH": (4, 4), "SI": (8, 8), "SK": (9, 9),
        "SL": (8, 8), "SM": (10, 10), "SN": (9, 9), "SO": (7, 9), "SR": (6, 7), "SS": (9, 9),
        "ST": (7, 7), "SV": (8, 8), "SX": (10, 10), "SY": (9, 9), "SZ": (8, 8), "TC": (10, 10),
        "TD": (8, 8), "TG": (8, 8), "TH": (9, 9), "TJ": (9, 9), "TL": (7, 8), "TM": (8, 8),
        "TN": (8, 8), "TO": (5, 7), "TR": (10, 10), "TT": (10, 10), "TV": (5, 7), "TW": (9, 9),
        "TZ": (9, 9), "UA": (9, 9), "UG": (9, 9), "US": (10, 10), "UY": (8, 8), "UZ": (9, 9),
        "VA": (10, 10), "VC": (10, 10), "VE": (10, 10), "VG": (10, 10), "VI": (10, 10), "VN": (9, 10),
        "VU": (5, 7), "WF": (6, 6), "WS": (5, 7), "XK": (8, 8), "YE": (9, 9), "YT": (9, 9),
        "ZA": (9, 9), "ZM": (9, 9), "ZW": (9, 9),
    ]

    /// ISO alpha-2 → E.164 country calling code.
    private static let dialCodes: [String: String] = [
        "AF": "93", "AL": "355", "DZ": "213", "AD": "376", "AO": "244", "AG": "1", "AR": "54",
        "AM": "374", "AU": "61", "AT": "43", "AZ": "994", "BS": "1", "BH": "973", "BD": "880",
        "BB": "1", "BY": "375", "BE": "32", "BZ": "501", "BJ": "229", "BT": "975", "BO": "591",
        "BA": "387", "BW": "267", "BR": "55", "BN": "673", "BG": "359", "BF": "226", "BI": "257",
        "KH": "855", "CM": "237", "CA": "1", "CV": "238", "CF": "236", "TD": "235", "CL": "56",
        "CN": "86", "CO": "57", "KM": "269", "CG": "242", "CD": "243", "CR": "506", "CI": "225",
        "HR": "385", "CU": "53", "CY": "357", "CZ": "420", "DK": "45", "DJ": "253", "DM": "1",
        "DO": "1", "EC": "593", "EG": "20", "SV": "503", "GQ": "240", "ER": "291", "EE": "372",
        "SZ": "268", "ET": "251", "FJ": "679", "FI": "358", "FR": "33", "GA": "241", "GM": "220",
        "GE": "995", "DE": "49", "GH": "233", "GR": "30", "GD": "1", "GT": "502", "GN": "224",
        "GW": "245", "GY": "592", "HT": "509", "HN": "504", "HK": "852", "HU": "36", "IS": "354",
        "IN": "91", "ID": "62", "IR": "98", "IQ": "964", "IE": "353", "IL": "972", "IT": "39",
        "JM": "1", "JP": "81", "JO": "962", "KZ": "7", "KE": "254", "KI": "686", "KW": "965",
        "KG": "996", "LA": "856", "LV": "371", "LB": "961", "LS": "266", "LR": "231", "LY": "218",
        "LI": "423", "LT": "370", "LU": "352", "MO": "853", "MG": "261", "MW": "265", "MY": "60",
        "MV": "960", "ML": "223", "MT": "356", "MH": "692", "MR": "222", "MU": "230", "MX": "52",
        "FM": "691", "MD": "373", "MC": "377", "MN": "976", "ME": "382", "MA": "212", "MZ": "258",
        "MM": "95", "NA": "264", "NR": "674", "NP": "977", "NL": "31", "NZ": "64", "NI": "505",
        "NE": "227", "NG": "234", "KP": "850", "MK": "389", "NO": "47", "OM": "968", "PK": "92",
        "PW": "680", "PA": "507", "PG": "675", "PY": "595", "PE": "51", "PH": "63", "PL": "48",
        "PT": "351", "QA": "974", "RO": "40", "RU": "7", "RW": "250", "KN": "1", "LC": "1",
        "VC": "1", "WS": "685", "SM": "378", "ST": "239", "SA": "966", "SN": "221", "RS": "381",
        "SC": "248", "SL": "232", "SG": "65", "SK": "421", "SI": "386", "SB": "677", "SO": "252",
        "ZA": "27", "KR": "82", "SS": "211", "ES": "34", "LK": "94", "SD": "249", "SR": "597",
        "SE": "46", "CH": "41", "SY": "963", "TW": "886", "TJ": "992", "TZ": "255", "TH": "66",
        "TL": "670", "TG": "228", "TO": "676", "TT": "1", "TN": "216", "TR": "90", "TM": "993",
        "TV": "688", "UG": "256", "UA": "380", "AE": "971", "GB": "44", "US": "1", "UY": "598",
        "UZ": "998", "VU": "678", "VA": "39", "VE": "58", "VN": "84", "YE": "967", "ZM": "260",
        "ZW": "263",
    ]
}
