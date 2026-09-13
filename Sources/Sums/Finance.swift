//
//  Finance.swift
//  Sums
//

import Foundation

/// Time-value-of-money functions, with the signs people expect rather than
/// a spreadsheet's cash-flow convention: a loan of 2 000 000 kr has a positive
/// monthly payment.
enum Finance {
    /// The payment per period that pays off `presentValue` over `periods`,
    /// leaving `futureValue` at the end.
    static func payment(rate: Double, periods: Double, presentValue: Double, futureValue: Double = 0) -> Double {
        guard periods > 0 else { return .nan }
        guard rate != 0 else { return (presentValue + futureValue) / periods }
        let growth = pow(1 + rate, periods)
        return rate * (presentValue * growth + futureValue) / (growth - 1)
    }

    /// What `payment` every period, plus `presentValue` today, grows to.
    static func futureValue(rate: Double, periods: Double, payment: Double, presentValue: Double = 0) -> Double {
        guard rate != 0 else { return presentValue + payment * periods }
        let growth = pow(1 + rate, periods)
        return presentValue * growth + payment * (growth - 1) / rate
    }

    /// What `payment` every period, plus `futureValue` at the end, is worth
    /// today.
    static func presentValue(rate: Double, periods: Double, payment: Double, futureValue: Double = 0) -> Double {
        guard rate != 0 else { return payment * periods + futureValue }
        let discount = pow(1 + rate, -periods)
        return payment * (1 - discount) / rate + futureValue * discount
    }

    /// Cash flows discounted to today, the first one period from now, as a
    /// spreadsheet's NPV counts them.
    static func netPresentValue(rate: Double, cashFlows: [Double]) -> Double {
        cashFlows.enumerated().reduce(0) { total, flow in
            total + flow.element / pow(1 + rate, Double(flow.offset + 1))
        }
    }

    /// The rate at which the cash flows, the first one today, are worth
    /// nothing. `nil` when there is none: the flows never change sign.
    static func internalRateOfReturn(_ cashFlows: [Double]) -> Double? {
        guard cashFlows.contains(where: { $0 < 0 }), cashFlows.contains(where: { $0 > 0 }) else { return nil }
        func value(_ rate: Double) -> Double {
            cashFlows.enumerated().reduce(0) { $0 + $1.element / pow(1 + rate, Double($1.offset)) }
        }
        // Newton first, from a sensible guess; bisection if it wanders off.
        var rate = 0.1
        for _ in 0..<50 {
            let f = value(rate)
            let slope = cashFlows.enumerated().reduce(0) { total, flow in
                total - Double(flow.offset) * flow.element / pow(1 + rate, Double(flow.offset) + 1)
            }
            guard slope != 0, rate > -0.99 else { break }
            let next = rate - f / slope
            if abs(next - rate) < 1e-12 { return next }
            rate = next
        }
        if abs(value(rate)) < 1e-7, rate > -0.99 { return rate }

        var low = -0.99, high = 10.0
        guard value(low).sign != value(high).sign else { return nil }
        for _ in 0..<200 {
            let middle = (low + high) / 2
            if value(low).sign == value(middle).sign { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }
}
