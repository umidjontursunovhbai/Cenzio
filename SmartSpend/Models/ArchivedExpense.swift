import Foundation

struct ArchivedExpense: Identifiable, Codable {
    let id: UUID
    let title: String
    let amount: Double
    let categoryId: UUID
    let date: Date
    let archivedDate: Date
    let notes: String?
    /// Kept so a restored expense stays linked to its Notion page (absent in older saves).
    let notionId: String?

    init(from expense: Expense) {
        self.id = expense.id
        self.title = expense.title
        self.amount = expense.amount
        self.categoryId = expense.categoryId
        self.date = expense.date
        self.archivedDate = Date()
        self.notes = nil
        self.notionId = expense.notionId
    }
}
