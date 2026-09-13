//
//  Templates.swift
//  Sums
//

import Foundation

/// A ready-made sheet the user can start from.
struct SheetTemplate: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// Written with Swedish number formatting (`1 000`, `7,5`); converted to
    /// the user's format when a sheet is created from it.
    let text: String

    /// The template's text in the number format the engine reads.
    func text(decimalSeparator: String) -> String {
        guard decimalSeparator == "." else { return text }
        return Self.toPointDecimals(text)
    }

    /// `1 234,50` becomes `1,234.50`. A comma followed by a space is a list
    /// separator (`12, 15`) and stays.
    static func toPointDecimals(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"(\d),(\d)"#, with: "$1.$2", options: .regularExpression)
            .replacingOccurrences(of: #"(\d) (?=\d{3}(?!\d))"#, with: "$1,", options: .regularExpression)
    }
}

enum Templates {
    static let quickGuide = SheetTemplate(
        id: "guide",
        title: "Quick guide",
        systemImage: "questionmark.circle",
        text: """
        # Welcome to Sums
        Type math on any line and the answer appears on the right.
        120 + 80
        Words are fine: coffee 45 + cake 38

        ## Percentages and VAT
        1 000 kr + 25%
        1 250 kr is 25% on what
        from 120 to 150 is what %

        ## Variables
        hourly rate = 650 kr
        hours = 7,5
        invoice = hourly rate × hours

        ## Totals
        Rent: 8 500 kr
        Food: 3 200 kr
        Transport: 970 kr
        total
        Also: average, median, std dev, count, min, max.
        Totals count the lines above, back to a blank line or heading.

        ## Statistics
        average of 12, 15, 9, 22
        median of 12, 15, 9, 22
        standard deviation of 12, 15, 9, 22

        ## Dates, times and units
        08:15 to 16:40
        days until 24 dec
        50 km in miles
        10 / 3 to 2 dp

        ## Tips
        - Click an answer to copy it. ⌥-click puts it at the cursor.
        - Select lines to see their sum, average, median and std dev.
        - prev is the answer on the line above: prev × 2
        - The sliders button turns variables into input fields.
        - **Markdown** works: # headings, - lists, - [ ] tasks, `code`, ==highlight==
        - ⌘N new sheet, ⌘[ back to the list, ⌘⌫ deletes the selected sheet.
        """
    )

    static let all: [SheetTemplate] = [
        quickGuide,
        SheetTemplate(
            id: "vat",
            title: "VAT calculator",
            systemImage: "percent",
            text: """
            # VAT calculator
            Change the price or the rate; everything below follows.
            > Swedish rates: 25 % for most things, 12 % food and hotels, 6 % books and travel.

            price = 1 000 kr
            vat rate = 25%
            vat = price × vat rate
            total = price + vat
            """
        ),
        SheetTemplate(
            id: "reverse-vat",
            title: "Price without VAT",
            systemImage: "arrow.uturn.backward",
            text: """
            # Price without VAT
            Enter a price that includes VAT.

            price incl vat = 1 250 kr
            vat rate = 25%
            price excl vat = price incl vat / (1 + vat rate)
            vat amount = price incl vat - price excl vat
            """
        ),
        SheetTemplate(
            id: "discount",
            title: "Discount",
            systemImage: "tag",
            text: """
            # Discount
            price = 800 kr
            discount = 15%
            sale price = price - discount
            you save = price × discount
            """
        ),
        SheetTemplate(
            id: "margin",
            title: "Markup and margin",
            systemImage: "chart.bar",
            text: """
            # Markup and margin
            Markup is added to the cost. Margin is the share of the price you keep.

            cost = 600 kr
            markup = 40%
            price = cost + markup
            profit = price - cost
            margin = profit / price as %
            """
        ),
        SheetTemplate(
            id: "loan",
            title: "Loan repayment",
            systemImage: "house",
            text: """
            # Loan repayment
            Monthly payment on an annuity loan.

            loan = 2 000 000 kr
            interest rate = 4
            years = 30
            r = interest rate / 100 / 12
            n = years × 12
            monthly payment = loan × r / (1 - (1 + r)^(-n))
            total paid = monthly payment × n
            total interest = total paid - loan
            """
        ),
        SheetTemplate(
            id: "savings",
            title: "Savings",
            systemImage: "banknote",
            text: """
            # Savings
            Saving every month, with the return compounding monthly.

            monthly saving = 1 500 kr
            yearly return = 7
            years = 20
            r = yearly return / 100 / 12
            n = years × 12
            future value = monthly saving × ((1 + r)^n - 1) / r
            deposited = monthly saving × n
            growth = future value - deposited

            ## A one-off amount
            25 000 kr over 10 years at 7,5%
            """
        ),
        SheetTemplate(
            id: "break-even",
            title: "Break-even",
            systemImage: "scalemass",
            text: """
            # Break-even
            fixed costs = 50 000 kr
            unit price = 250 kr
            unit cost = 150 kr
            contribution = unit price - unit cost
            break-even units = fixed costs / contribution
            break-even revenue = break-even units × unit price
            """
        ),
        SheetTemplate(
            id: "cagr",
            title: "Growth rate (CAGR)",
            systemImage: "chart.line.uptrend.xyaxis",
            text: """
            # Growth rate (CAGR)
            start value = 100 000 kr
            end value = 180 000 kr
            years = 5
            growth per year = (end value / start value)^(1 / years) - 1
            growth per year as %
            """
        ),
        SheetTemplate(
            id: "percent-change",
            title: "Percentage change",
            systemImage: "plusminus",
            text: """
            # Percentage change
            from 120 to 150 is what %
            150 is what % of 120
            120 + 25%
            150 - 20%
            40 is 25% of what
            """
        ),
        SheetTemplate(
            id: "budget",
            title: "Monthly budget",
            systemImage: "list.bullet.rectangle",
            text: """
            # Monthly budget
            income = 32 000 kr

            ## Expenses
            Rent: 8 500 kr
            Food: 3 200 kr
            Transport: 970 kr
            Phone: 299 kr
            expenses = total

            left = income - expenses
            """
        ),
        SheetTemplate(
            id: "statistics",
            title: "Statistics",
            systemImage: "function",
            text: """
            # Statistics
            One value per line, then ask for what you need.

            12
            15
            9
            22
            18
            average
            median
            std dev
            min
            max
            """
        )
    ]
}
