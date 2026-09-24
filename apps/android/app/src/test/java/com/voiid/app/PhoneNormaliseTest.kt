package com.voiid.app

import com.voiid.app.onboarding.Country
import com.voiid.app.onboarding.normalisePhone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The phone field's normalisation — the one failure on that screen that is invisible until the
 * SMS never arrives: autofill hands back "+91 98765 43210", and naive digit-stripping sends
 * a 12-digit number that LOOKS correctly entered.
 */
class PhoneNormaliseTest {
    private val india = Country("IN", "India", "+91", "", minDigits = 10, maxDigits = 10)
    private val uk = Country("GB", "United Kingdom", "+44", "", minDigits = 9, maxDigits = 10)

    @Test fun plainNationalNumberIsKept() =
        assertEquals("9876543210", normalisePhone("98765 43210", india))

    @Test fun autofilledInternationalNumberLosesItsDialCode() =
        assertEquals("9876543210", normalisePhone("+91 98765 43210", india))

    @Test fun trunkZeroIsStripped() =
        assertEquals("9876543210", normalisePhone("09876543210", india))

    @Test fun nationalNumberStartingWithDialDigitsIsNotMangled() =
        // A 10-digit Indian number that happens to begin "91" is not over-long, so nothing
        // is stripped.
        assertEquals("9112345678", normalisePhone("9112345678", india))

    @Test fun strippingThatWouldLeaveTooFewDigitsIsRefused() =
        // 11 digits starting "91": stripping leaves 9 < India's min 10, so the guard keeps
        // the digits (then caps at max) rather than producing an impossible number.
        assertEquals("9112345678", normalisePhone("91123456789", india))

    @Test fun strippingIsKeptWhenWhatRemainsIsPlausible() =
        // 11 digits starting "44": stripping leaves 9 ≥ the UK's min 9.
        assertEquals("123456789", normalisePhone("44123456789", uk))

    @Test fun resultIsCappedAtTheCountryMaximum() =
        assertEquals("9876543210", normalisePhone("98765432109999", india))

    @Test fun numberTypedWithPlusIsNeverCappedIntoAWrongNumber() {
        // Typed by hand, one key at a time. Every intermediate value must be a PREFIX of the
        // real national number — never a full-length number that isn't it.
        val typed = "+919876543210"
        for (end in 1..typed.length) {
            val n = normalisePhone(typed.substring(0, end), india)
            assertTrue("\"${typed.substring(0, end)}\" → \"$n\"", "9876543210".startsWith(n))
        }
        assertEquals("9876543210", normalisePhone(typed, india))
    }

    @Test fun bareDigitsStillUseTheLengthGuard() =
        // No "+": "91" might be the start of the national number, so the guard decides.
        assertEquals("9112345678", normalisePhone("91123456789", india))
}
