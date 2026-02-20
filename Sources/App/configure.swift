import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Vapor

func configureDatabase(app: Application) throws {
    let backend = Environment.get("STORAGE_BACKEND") ?? "sqlite"

    switch backend {
    case "postgres":
        if let url = Environment.get("DATABASE_URL") {
            try app.databases.use(.postgres(url: url), as: .psql)
        }
    case "sqlite":
        let path = Environment.get("DATABASE_URL") ?? "zelo.db"
        app.databases.use(.sqlite(.file(path)), as: .sqlite)
    default:
        break  // JSON file storage doesn't need Fluent
    }
}
