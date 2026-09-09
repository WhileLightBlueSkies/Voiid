package com.voiid.app.onboarding

import java.util.Locale

/**
 * Full country list for the phone-number selector — port of iOS `Countries.swift`.
 * Names + flags derive from the device locale; dial codes from a static ISO-3166-1 alpha-2 map.
 * India is the default.
 */
data class Country(
    val id: String,        // ISO region code, e.g. "IN"
    val name: String,      // localized country name
    val dialCode: String,  // e.g. "+91"
    val flag: String,      // emoji flag
    /**
     * Plausible national-number length, used to enable Continue and to bound autofill
     * normalisation.
     *
     * NOT A VALIDITY CHECK. Several countries have genuinely variable formats and carry a wide
     * range rather than a wrong one; the SMS is the real validator. These exist so the button
     * cannot be tapped on an obviously incomplete number, and so `normalise` knows when a
     * leading dial code is spurious rather than part of the number.
     */
    val minDigits: Int,
    val maxDigits: Int,
)

object CountryStore {
    /** All countries with a known dial code, sorted by localized name. */
    val all: List<Country> by lazy {
        Locale.getISOCountries()
            .mapNotNull { code ->
                val dial = dialCodes[code] ?: return@mapNotNull null
                val name = Locale("", code).getDisplayCountry(Locale.getDefault())
                if (name.isBlank()) return@mapNotNull null
                // Countries with no measured range fall back to 4..15 — E.164 permits at most
                // 15 digits including the dial code, so this rejects nothing legitimate while
                // still catching an empty or one-digit entry.
                val (lo, hi) = digitBounds[code] ?: (4 to 15)
                Country(
                    id = code, name = name, dialCode = "+$dial", flag = flagEmoji(code),
                    minDigits = lo, maxDigits = hi,
                )
            }
            .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
    }

    /**
     * India. A `by lazy` rather than a `get()`: the getter re-scanned all ~195 countries on
     * every access, and this is read on every recomposition of the phone field.
     */
    val default: Country by lazy { all.firstOrNull { it.id == "IN" } ?: all.first() }

    /** Regional-indicator flag emoji from a 2-letter region code. */
    private fun flagEmoji(code: String): String =
        code.uppercase().map { String(Character.toChars(127397 + it.code)) }.joinToString("")

    /**
     * ISO alpha-2 → plausible national-number length (min, max), EXCLUDING the dial code.
     *
     * 237 entries, ported verbatim from iOS `Countries.swift`, which took them from the design
     * reference's table. Only a gate for the Continue button and for autofill normalisation —
     * see the note on [Country.minDigits]. Keep the two tables identical: a number Android
     * accepts and iOS rejects is a support ticket nobody can reproduce.
     */
    private val digitBounds: Map<String, Pair<Int, Int>> = mapOf(
        "AD" to (6 to 9), "AE" to (9 to 9), "AF" to (9 to 9), "AG" to (10 to 10), "AI" to (10 to 10), "AL" to (8 to 9),
        "AM" to (8 to 8), "AO" to (9 to 9), "AR" to (10 to 11), "AS" to (10 to 10), "AT" to (4 to 13), "AU" to (9 to 9),
        "AW" to (7 to 7), "AX" to (6 to 12), "AZ" to (9 to 9), "BA" to (8 to 9), "BB" to (10 to 10), "BD" to (6 to 10),
        "BE" to (8 to 9), "BF" to (8 to 8), "BG" to (7 to 9), "BH" to (8 to 8), "BI" to (8 to 8), "BJ" to (8 to 8),
        "BL" to (9 to 9), "BM" to (10 to 10), "BN" to (7 to 7), "BO" to (8 to 8), "BQ" to (7 to 7), "BR" to (10 to 11),
        "BS" to (10 to 10), "BT" to (7 to 8), "BW" to (7 to 8), "BY" to (9 to 9), "BZ" to (7 to 7), "CA" to (10 to 10),
        "CD" to (9 to 9), "CF" to (8 to 8), "CG" to (9 to 9), "CH" to (9 to 9), "CI" to (8 to 10), "CK" to (5 to 5),
        "CL" to (9 to 9), "CM" to (9 to 9), "CN" to (11 to 11), "CO" to (10 to 10), "CR" to (8 to 8), "CU" to (8 to 8),
        "CV" to (7 to 7), "CW" to (7 to 8), "CY" to (8 to 8), "CZ" to (9 to 9), "DE" to (6 to 11), "DJ" to (8 to 8),
        "DK" to (8 to 8), "DM" to (10 to 10), "DO" to (10 to 10), "DZ" to (9 to 9), "EC" to (9 to 9), "EE" to (7 to 8),
        "EG" to (10 to 10), "ER" to (7 to 7), "ES" to (9 to 9), "ET" to (9 to 9), "FI" to (6 to 12), "FJ" to (7 to 7),
        "FK" to (5 to 5), "FM" to (7 to 7), "FO" to (6 to 6), "FR" to (9 to 9), "GA" to (7 to 8), "GB" to (10 to 10),
        "GD" to (10 to 10), "GE" to (9 to 9), "GF" to (9 to 9), "GG" to (10 to 10), "GH" to (9 to 9), "GI" to (8 to 8),
        "GL" to (6 to 6), "GM" to (7 to 7), "GN" to (9 to 9), "GP" to (9 to 9), "GQ" to (9 to 9), "GR" to (10 to 10),
        "GT" to (8 to 8), "GU" to (10 to 10), "GW" to (9 to 9), "GY" to (7 to 7), "HK" to (8 to 8), "HN" to (8 to 8),
        "HR" to (8 to 9), "HT" to (8 to 8), "HU" to (9 to 9), "ID" to (9 to 12), "IE" to (9 to 9), "IL" to (9 to 9),
        "IM" to (10 to 10), "IN" to (10 to 10), "IQ" to (10 to 10), "IR" to (10 to 10), "IS" to (7 to 9), "IT" to (9 to 11),
        "JE" to (10 to 10), "JM" to (10 to 10), "JO" to (9 to 9), "JP" to (10 to 10), "KE" to (9 to 9), "KG" to (9 to 9),
        "KH" to (8 to 9), "KI" to (5 to 8), "KM" to (7 to 7), "KN" to (10 to 10), "KP" to (4 to 13), "KR" to (9 to 10),
        "KW" to (8 to 8), "KY" to (10 to 10), "KZ" to (10 to 10), "LA" to (8 to 10), "LB" to (7 to 8), "LC" to (10 to 10),
        "LI" to (7 to 7), "LK" to (9 to 9), "LR" to (8 to 9), "LS" to (8 to 8), "LT" to (8 to 8), "LU" to (9 to 9),
        "LV" to (8 to 8), "LY" to (9 to 9), "MA" to (9 to 9), "MC" to (8 to 9), "MD" to (8 to 8), "ME" to (8 to 8),
        "MF" to (9 to 9), "MG" to (9 to 9), "MH" to (7 to 7), "MK" to (8 to 8), "ML" to (8 to 8), "MM" to (8 to 10),
        "MN" to (8 to 8), "MO" to (8 to 8), "MP" to (10 to 10), "MQ" to (9 to 9), "MR" to (8 to 8), "MS" to (10 to 10),
        "MT" to (8 to 8), "MU" to (7 to 8), "MV" to (7 to 7), "MW" to (7 to 9), "MX" to (10 to 10), "MY" to (9 to 10),
        "MZ" to (9 to 9), "NA" to (9 to 9), "NC" to (6 to 6), "NE" to (8 to 8), "NF" to (6 to 6), "NG" to (8 to 10),
        "NI" to (8 to 8), "NL" to (9 to 9), "NO" to (8 to 8), "NP" to (10 to 10), "NR" to (7 to 7), "NU" to (4 to 4),
        "NZ" to (8 to 10), "OM" to (8 to 8), "PA" to (8 to 8), "PE" to (9 to 9), "PF" to (6 to 6), "PG" to (8 to 8),
        "PH" to (10 to 10), "PK" to (10 to 10), "PL" to (9 to 9), "PM" to (6 to 6), "PR" to (10 to 10), "PS" to (9 to 9),
        "PT" to (9 to 9), "PW" to (7 to 7), "PY" to (9 to 9), "QA" to (8 to 8), "RE" to (9 to 9), "RO" to (9 to 9),
        "RS" to (8 to 9), "RU" to (10 to 10), "RW" to (9 to 9), "SA" to (9 to 9), "SB" to (5 to 7), "SC" to (7 to 7),
        "SD" to (9 to 9), "SE" to (7 to 13), "SG" to (8 to 8), "SH" to (4 to 4), "SI" to (8 to 8), "SK" to (9 to 9),
        "SL" to (8 to 8), "SM" to (10 to 10), "SN" to (9 to 9), "SO" to (7 to 9), "SR" to (6 to 7), "SS" to (9 to 9),
        "ST" to (7 to 7), "SV" to (8 to 8), "SX" to (10 to 10), "SY" to (9 to 9), "SZ" to (8 to 8), "TC" to (10 to 10),
        "TD" to (8 to 8), "TG" to (8 to 8), "TH" to (9 to 9), "TJ" to (9 to 9), "TL" to (7 to 8), "TM" to (8 to 8),
        "TN" to (8 to 8), "TO" to (5 to 7), "TR" to (10 to 10), "TT" to (10 to 10), "TV" to (5 to 7), "TW" to (9 to 9),
        "TZ" to (9 to 9), "UA" to (9 to 9), "UG" to (9 to 9), "US" to (10 to 10), "UY" to (8 to 8), "UZ" to (9 to 9),
        "VA" to (10 to 10), "VC" to (10 to 10), "VE" to (10 to 10), "VG" to (10 to 10), "VI" to (10 to 10), "VN" to (9 to 10),
        "VU" to (5 to 7), "WF" to (6 to 6), "WS" to (5 to 7), "XK" to (8 to 8), "YE" to (9 to 9), "YT" to (9 to 9),
        "ZA" to (9 to 9), "ZM" to (9 to 9), "ZW" to (9 to 9),
    )

    /** ISO alpha-2 → E.164 country calling code. */
    private val dialCodes: Map<String, String> = mapOf(
        "AF" to "93", "AL" to "355", "DZ" to "213", "AD" to "376", "AO" to "244", "AG" to "1", "AR" to "54",
        "AM" to "374", "AU" to "61", "AT" to "43", "AZ" to "994", "BS" to "1", "BH" to "973", "BD" to "880",
        "BB" to "1", "BY" to "375", "BE" to "32", "BZ" to "501", "BJ" to "229", "BT" to "975", "BO" to "591",
        "BA" to "387", "BW" to "267", "BR" to "55", "BN" to "673", "BG" to "359", "BF" to "226", "BI" to "257",
        "KH" to "855", "CM" to "237", "CA" to "1", "CV" to "238", "CF" to "236", "TD" to "235", "CL" to "56",
        "CN" to "86", "CO" to "57", "KM" to "269", "CG" to "242", "CD" to "243", "CR" to "506", "CI" to "225",
        "HR" to "385", "CU" to "53", "CY" to "357", "CZ" to "420", "DK" to "45", "DJ" to "253", "DM" to "1",
        "DO" to "1", "EC" to "593", "EG" to "20", "SV" to "503", "GQ" to "240", "ER" to "291", "EE" to "372",
        "SZ" to "268", "ET" to "251", "FJ" to "679", "FI" to "358", "FR" to "33", "GA" to "241", "GM" to "220",
        "GE" to "995", "DE" to "49", "GH" to "233", "GR" to "30", "GD" to "1", "GT" to "502", "GN" to "224",
        "GW" to "245", "GY" to "592", "HT" to "509", "HN" to "504", "HK" to "852", "HU" to "36", "IS" to "354",
        "IN" to "91", "ID" to "62", "IR" to "98", "IQ" to "964", "IE" to "353", "IL" to "972", "IT" to "39",
        "JM" to "1", "JP" to "81", "JO" to "962", "KZ" to "7", "KE" to "254", "KI" to "686", "KW" to "965",
        "KG" to "996", "LA" to "856", "LV" to "371", "LB" to "961", "LS" to "266", "LR" to "231", "LY" to "218",
        "LI" to "423", "LT" to "370", "LU" to "352", "MO" to "853", "MG" to "261", "MW" to "265", "MY" to "60",
        "MV" to "960", "ML" to "223", "MT" to "356", "MH" to "692", "MR" to "222", "MU" to "230", "MX" to "52",
        "FM" to "691", "MD" to "373", "MC" to "377", "MN" to "976", "ME" to "382", "MA" to "212", "MZ" to "258",
        "MM" to "95", "NA" to "264", "NR" to "674", "NP" to "977", "NL" to "31", "NZ" to "64", "NI" to "505",
        "NE" to "227", "NG" to "234", "KP" to "850", "MK" to "389", "NO" to "47", "OM" to "968", "PK" to "92",
        "PW" to "680", "PA" to "507", "PG" to "675", "PY" to "595", "PE" to "51", "PH" to "63", "PL" to "48",
        "PT" to "351", "QA" to "974", "RO" to "40", "RU" to "7", "RW" to "250", "KN" to "1", "LC" to "1",
        "VC" to "1", "WS" to "685", "SM" to "378", "ST" to "239", "SA" to "966", "SN" to "221", "RS" to "381",
        "SC" to "248", "SL" to "232", "SG" to "65", "SK" to "421", "SI" to "386", "SB" to "677", "SO" to "252",
        "ZA" to "27", "KR" to "82", "SS" to "211", "ES" to "34", "LK" to "94", "SD" to "249", "SR" to "597",
        "SE" to "46", "CH" to "41", "SY" to "963", "TW" to "886", "TJ" to "992", "TZ" to "255", "TH" to "66",
        "TL" to "670", "TG" to "228", "TO" to "676", "TT" to "1", "TN" to "216", "TR" to "90", "TM" to "993",
        "TV" to "688", "UG" to "256", "UA" to "380", "AE" to "971", "GB" to "44", "US" to "1", "UY" to "598",
        "UZ" to "998", "VU" to "678", "VA" to "39", "VE" to "58", "VN" to "84", "YE" to "967", "ZM" to "260",
        "ZW" to "263",
    )
}
