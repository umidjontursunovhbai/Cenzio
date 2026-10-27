import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct SmartSpendControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.tursunov.Cenzio.AddExpense") {
            ControlWidgetButton(action: OpenAddExpenseIntent()) {
                Label("Quick Add", systemImage: "plus.circle.fill")
            }
        }
        .displayName("Cenzio Quick Add")
        .description("Open Cenzio to add a new expense")
    }
}
