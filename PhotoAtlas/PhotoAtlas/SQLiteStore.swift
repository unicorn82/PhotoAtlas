import Foundation
import SQLite3
import CoreLocation

struct PhotoRecord: Sendable {
    let localId: String
    let creationTs: Double?
    let lat: Double?
    let lon: Double?

    let countryCode: String?
    let countryName: String?
    let city: String?
}

struct ClusterBubble: Identifiable, Sendable {
    /// Cluster key, e.g. "country:US" or "city:Denver|US".
    let id: String
    let title: String
    let count: Int
    let centerLat: Double
    let centerLon: Double
}

enum ClusterPrecision: Sendable, Equatable {
    case country
    case city
}

struct CountryDiarySummary: Sendable {
    struct Highlight: Sendable {
        /// Stable id for SwiftUI/transfer.
        let id: String
        /// Raw string so SQLiteStore stays independent of UI module enums.
        let kindRaw: String
        let countryCode: String
        let countryName: String
        let count: Int?
        let yearsLine: String?
    }

    let countriesCount: Int
    let dateRange: String
    let highlights: [Highlight]
}

actor SQLiteStore {
    private var db: OpaquePointer?

    /// Returns a centroid of all photos with GPS, if any.
    func photosCentroid() throws -> CLLocationCoordinate2D? {
        guard let db = db else { throw SQLiteError.notOpen }

        let sql = """
        SELECT AVG(lat) AS clat, AVG(lon) AS clon, COUNT(*) AS cnt
        FROM photos
        WHERE lat IS NOT NULL AND lon IS NOT NULL;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let cnt = Int(sqlite3_column_int(stmt, 2))
        guard cnt > 0 else { return nil }

        let clat = sqlite3_column_double(stmt, 0)
        let clon = sqlite3_column_double(stmt, 1)
        return CLLocationCoordinate2D(latitude: clat, longitude: clon)
    }

    init() {
        do {
            try open()
            try migrate()
        } catch {
            fatalError("SQLite init failed: \(error)")
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func open() throws {
        let url = try Self.dbURL()
        var db: OpaquePointer?
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            throw SQLiteError.openFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        self.db = db

        _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA temp_store=MEMORY;", nil, nil, nil)
    }

    private static func dbURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("PhotoAtlas", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("photoatlas.sqlite")
    }

    private func migrate() throws {
        guard let db = db else { throw SQLiteError.notOpen }

        // v1 table (MVP). If you change schema, bump migrations later.
        let sql = """
        CREATE TABLE IF NOT EXISTS photos (
          local_id      TEXT PRIMARY KEY,
          creation_ts   REAL,
          lat           REAL,
          lon           REAL,
          country_code  TEXT,
          country_name  TEXT,
          city          TEXT,
          imported_ts   REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_photos_latlon ON photos(lat, lon);
        CREATE INDEX IF NOT EXISTS idx_photos_country ON photos(country_code);
        CREATE INDEX IF NOT EXISTS idx_photos_city_country ON photos(city, country_code);
        CREATE INDEX IF NOT EXISTS idx_photos_creation ON photos(creation_ts);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw SQLiteError.execFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        // v2: user annotations (favorites + comments)
        try ensureColumn("is_favorite", alterSQL: "ALTER TABLE photos ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;")
        try ensureColumn("comment", alterSQL: "ALTER TABLE photos ADD COLUMN comment TEXT;")

        if sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_photos_favorite ON photos(is_favorite);", nil, nil, nil) != SQLITE_OK {
            throw SQLiteError.execFailed(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func ensureColumn(_ name: String, alterSQL: String) throws {
        guard let db = db else { throw SQLiteError.notOpen }

        let sql = "PRAGMA table_info(photos);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        var found = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            // Column name is at index 1
            let col = String(cString: sqlite3_column_text(stmt, 1))
            if col == name {
                found = true
                break
            }
        }

        if !found {
            if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
                throw SQLiteError.execFailed(message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func resetAll() throws {
        guard let db = db else { throw SQLiteError.notOpen }
        if sqlite3_exec(db, "DELETE FROM photos;", nil, nil, nil) != SQLITE_OK {
            throw SQLiteError.execFailed(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Latest time we imported/indexed any photo into the DB.
    /// Use this to drive incremental indexing on next app launch.
    func latestImportedTs() throws -> Double? {
        guard let db = db else { throw SQLiteError.notOpen }

        let sql = "SELECT MAX(imported_ts) FROM photos;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    func upsert(_ record: PhotoRecord, importedTs: Double = Date().timeIntervalSince1970) throws {
        guard let db = db else { throw SQLiteError.notOpen }

        let sql = """
        INSERT INTO photos(local_id, creation_ts, lat, lon, country_code, country_name, city, imported_ts)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(local_id) DO UPDATE SET
          creation_ts=excluded.creation_ts,
          lat=excluded.lat,
          lon=excluded.lon,
          country_code=excluded.country_code,
          country_name=excluded.country_name,
          city=excluded.city,
          imported_ts=excluded.imported_ts;
        """
        // NOTE: We intentionally do NOT touch user-generated columns (is_favorite, comment)
        // during re-indexing/upserts. Those are owned by the user.

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_text(stmt, 1, record.localId, -1, SQLITE_TRANSIENT)
        bindDouble(stmt, 2, record.creationTs)
        bindDouble(stmt, 3, record.lat)
        bindDouble(stmt, 4, record.lon)
        bindText(stmt, 5, record.countryCode)
        bindText(stmt, 6, record.countryName)
        bindText(stmt, 7, record.city)
        sqlite3_bind_double(stmt, 8, importedTs)

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw SQLiteError.stepFailed(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    func clusters(in bbox: BBox, precision: ClusterPrecision) throws -> [ClusterBubble] {
        guard let db = db else { throw SQLiteError.notOpen }

        let (groupExpr, idPrefix, titleExpr): (String, String, String) = {
            switch precision {
            case .country:
                return ("country_code", "country:", "COALESCE(country_name, country_code, '??')")
            case .city:
                // Compose a stable key: city|country
                return ("(COALESCE(city, '(Unknown)') || '|' || COALESCE(country_code, '??'))", "city:", "COALESCE(city, '(Unknown)')")
            }
        }()

        let sql = """
        SELECT
          \(groupExpr) AS key,
          COUNT(*) AS cnt,
          AVG(lat) AS clat,
          AVG(lon) AS clon,
          \(titleExpr) AS title
        FROM photos
        WHERE lat IS NOT NULL AND lon IS NOT NULL
          AND lat BETWEEN ? AND ?
          AND lon BETWEEN ? AND ?
          AND \(groupExpr) IS NOT NULL
        GROUP BY key
        ORDER BY cnt DESC
        LIMIT 500;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_double(stmt, 1, bbox.minLat)
        sqlite3_bind_double(stmt, 2, bbox.maxLat)
        sqlite3_bind_double(stmt, 3, bbox.minLon)
        sqlite3_bind_double(stmt, 4, bbox.maxLon)

        var out: [ClusterBubble] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let cnt = Int(sqlite3_column_int(stmt, 1))
            let clat = sqlite3_column_double(stmt, 2)
            let clon = sqlite3_column_double(stmt, 3)
            let title = String(cString: sqlite3_column_text(stmt, 4))

            out.append(
                ClusterBubble(
                    id: "\(idPrefix)\(key)",
                    title: title,
                    count: cnt,
                    centerLat: clat,
                    centerLon: clon
                )
            )
        }
        return out
    }

    func photoIds(inCluster clusterKey: String, precision: ClusterPrecision) throws -> [(localId: String, creationTs: Double?, isFavorite: Bool, hasComment: Bool)] {
        guard let db = db else { throw SQLiteError.notOpen }

        let sql: String
        let bindings: [String]

        switch precision {
        case .country:
            // clusterKey: country:US
            let code = clusterKey.replacingOccurrences(of: "country:", with: "")
            sql = """
            SELECT local_id,
                   creation_ts,
                   COALESCE(is_favorite, 0) AS is_favorite,
                   CASE WHEN comment IS NOT NULL AND LENGTH(TRIM(comment)) > 0 THEN 1 ELSE 0 END AS has_comment
            FROM photos
            WHERE country_code = ?
            ORDER BY creation_ts DESC;
            """
            bindings = [code]

        case .city:
            // clusterKey: city:Denver|US
            let raw = clusterKey.replacingOccurrences(of: "city:", with: "")
            let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
            let city = parts.first.map(String.init) ?? "(Unknown)"
            let code = parts.dropFirst().first.map(String.init) ?? "??"

            sql = """
            SELECT local_id,
                   creation_ts,
                   COALESCE(is_favorite, 0) AS is_favorite,
                   CASE WHEN comment IS NOT NULL AND LENGTH(TRIM(comment)) > 0 THEN 1 ELSE 0 END AS has_comment
            FROM photos
            WHERE COALESCE(city, '(Unknown)') = ? AND COALESCE(country_code, '??') = ?
            ORDER BY creation_ts DESC;
            """
            bindings = [city, code]
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        for (i, b) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), b, -1, SQLITE_TRANSIENT)
        }

        var rows: [(String, Double?, Bool, Bool)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))

            let creation: Double?
            if sqlite3_column_type(stmt, 1) == SQLITE_NULL { creation = nil }
            else { creation = sqlite3_column_double(stmt, 1) }

            let fav = sqlite3_column_int(stmt, 2) != 0
            let hasComment = sqlite3_column_int(stmt, 3) != 0

            rows.append((id, creation, fav, hasComment))
        }
        return rows
    }

    func favoritePhotoIds(inCluster clusterKey: String, precision: ClusterPrecision) throws -> [(localId: String, creationTs: Double?, hasComment: Bool)] {
        guard let db = db else { throw SQLiteError.notOpen }

        let sql: String
        let bindings: [String]

        switch precision {
        case .country:
            let code = clusterKey.replacingOccurrences(of: "country:", with: "")
            sql = """
            SELECT local_id,
                   creation_ts,
                   CASE WHEN comment IS NOT NULL AND LENGTH(TRIM(comment)) > 0 THEN 1 ELSE 0 END AS has_comment
            FROM photos
            WHERE country_code = ? AND COALESCE(is_favorite, 0) = 1
            ORDER BY creation_ts DESC;
            """
            bindings = [code]

        case .city:
            let raw = clusterKey.replacingOccurrences(of: "city:", with: "")
            let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
            let city = parts.first.map(String.init) ?? "(Unknown)"
            let code = parts.dropFirst().first.map(String.init) ?? "??"

            sql = """
            SELECT local_id,
                   creation_ts,
                   CASE WHEN comment IS NOT NULL AND LENGTH(TRIM(comment)) > 0 THEN 1 ELSE 0 END AS has_comment
            FROM photos
            WHERE COALESCE(city, '(Unknown)') = ? AND COALESCE(country_code, '??') = ?
              AND COALESCE(is_favorite, 0) = 1
            ORDER BY creation_ts DESC;
            """
            bindings = [city, code]
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        for (i, b) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), b, -1, SQLITE_TRANSIENT)
        }

        var rows: [(String, Double?, Bool)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))

            let creation: Double?
            if sqlite3_column_type(stmt, 1) == SQLITE_NULL { creation = nil }
            else { creation = sqlite3_column_double(stmt, 1) }

            let hasComment = sqlite3_column_int(stmt, 2) != 0
            rows.append((id, creation, hasComment))
        }
        return rows
    }

    func photoUserData(localId: String) throws -> (isFavorite: Bool, comment: String?) {
        guard let db = db else { throw SQLiteError.notOpen }

        let sql = """
        SELECT COALESCE(is_favorite, 0) AS is_favorite, comment
        FROM photos
        WHERE local_id = ?
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_text(stmt, 1, localId, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return (isFavorite: false, comment: nil)
        }

        let fav = sqlite3_column_int(stmt, 0) != 0
        let comment: String?
        if sqlite3_column_type(stmt, 1) == SQLITE_NULL { comment = nil }
        else { comment = String(cString: sqlite3_column_text(stmt, 1)) }

        return (fav, comment)
    }

    func setFavorite(localId: String, isFavorite: Bool) throws {
        guard let db = db else { throw SQLiteError.notOpen }

        let sql = "UPDATE photos SET is_favorite = ? WHERE local_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int(stmt, 1, isFavorite ? 1 : 0)
        sqlite3_bind_text(stmt, 2, localId, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw SQLiteError.stepFailed(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    func setComment(localId: String, comment: String?) throws {
        guard let db = db else { throw SQLiteError.notOpen }

        let sql = "UPDATE photos SET comment = ? WHERE local_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }

        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed = trimmed, !trimmed.isEmpty {
            sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, localId, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw SQLiteError.stepFailed(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Binding helpers

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let value = value {
            sqlite3_bind_double(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    // MARK: - Diary summary

    /// Country-only shareable summary used by the Footprint Diary card.
    func countryDiarySummary() throws -> CountryDiarySummary {
        guard let db = db else { throw SQLiteError.notOpen }

        // 1) Countries count
        let countriesCount: Int = {
            let sql = "SELECT COUNT(DISTINCT country_code) FROM photos WHERE country_code IS NOT NULL;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }()

        // 2) Date range (from photo creation timestamps)
        let dateRange: String = {
            let sql = "SELECT MIN(creation_ts), MAX(creation_ts) FROM photos WHERE creation_ts IS NOT NULL;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return "All time"
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return "All time" }
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL || sqlite3_column_type(stmt, 1) == SQLITE_NULL {
                return "All time"
            }
            let minTs = sqlite3_column_double(stmt, 0)
            let maxTs = sqlite3_column_double(stmt, 1)
            let minYear = Calendar.current.component(.year, from: Date(timeIntervalSince1970: minTs))
            let maxYear = Calendar.current.component(.year, from: Date(timeIntervalSince1970: maxTs))
            return (minYear == maxYear) ? "\(minYear)" : "\(minYear)–\(maxYear)"
        }()

        // Helpers
        func countryName(forCode code: String?) -> String? {
            guard let code = code else { return nil }
            // Prefer stored country_name in DB; if absent, fall back to the code.
            let sql = "SELECT COALESCE(MAX(country_name), ?) FROM photos WHERE country_code = ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return code }
            sqlite3_bind_text(stmt, 1, code, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, code, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return code }
            if let cstr = sqlite3_column_text(stmt, 0) {
                return String(cString: cstr)
            }
            return code
        }

        func yearsLine(forCountryCode code: String) -> String? {
            let sql = "SELECT MIN(creation_ts), MAX(creation_ts) FROM photos WHERE country_code = ? AND creation_ts IS NOT NULL;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, code, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL || sqlite3_column_type(stmt, 1) == SQLITE_NULL { return nil }
            let minTs = sqlite3_column_double(stmt, 0)
            let maxTs = sqlite3_column_double(stmt, 1)
            let minYear = Calendar.current.component(.year, from: Date(timeIntervalSince1970: minTs))
            let maxYear = Calendar.current.component(.year, from: Date(timeIntervalSince1970: maxTs))
            return (minYear == maxYear) ? "\(minYear)" : "\(minYear) → \(maxYear)"
        }

        // 3) Highlights
        var highlights: [CountryDiarySummary.Highlight] = []

        // Most photographed country
        do {
            let sql = """
            SELECT country_code, COALESCE(country_name, country_code) AS name, COUNT(*) AS cnt
            FROM photos
            WHERE country_code IS NOT NULL
            GROUP BY country_code
            ORDER BY cnt DESC
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                let code = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "??"
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? code
                let cnt = Int(sqlite3_column_int(stmt, 2))

                // List up to 3 years (most recent distinct years) for diary flavor.
                let years: String? = {
                    let sql2 = """
                    SELECT DISTINCT CAST(strftime('%Y', datetime(creation_ts, 'unixepoch')) AS INTEGER) AS y
                    FROM photos
                    WHERE country_code = ? AND creation_ts IS NOT NULL
                    ORDER BY y ASC;
                    """
                    var stmt2: OpaquePointer?
                    defer { sqlite3_finalize(stmt2) }
                    guard sqlite3_prepare_v2(db, sql2, -1, &stmt2, nil) == SQLITE_OK else { return yearsLine(forCountryCode: code) }
                    sqlite3_bind_text(stmt2, 1, code, -1, SQLITE_TRANSIENT)
                    var ys: [Int] = []
                    while sqlite3_step(stmt2) == SQLITE_ROW {
                        ys.append(Int(sqlite3_column_int(stmt2, 0)))
                    }
                    if ys.isEmpty { return yearsLine(forCountryCode: code) }
                    // If many years, show first + last + one middle-ish.
                    if ys.count <= 3 {
                        return ys.map(String.init).joined(separator: ", ")
                    } else {
                        return "\(ys.first!) , \(ys[ys.count/2]) , \(ys.last!)".replacingOccurrences(of: " ,", with: ",")
                    }
                }()

                highlights.append(.init(
                    id: "mostPhotographed",
                    kindRaw: "mostPhotographed",
                    countryCode: code,
                    countryName: name,
                    count: cnt,
                    yearsLine: years
                ))
            }
        }

        // First stamp (earliest photo by creation_ts with a country)
        do {
            let sql = """
            SELECT country_code, COALESCE(country_name, country_code) AS name, MIN(creation_ts) AS min_ts
            FROM photos
            WHERE country_code IS NOT NULL AND creation_ts IS NOT NULL
            GROUP BY country_code
            ORDER BY min_ts ASC
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                let code = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "??"
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? code
                let minTs = sqlite3_column_double(stmt, 2)
                let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: minTs))
                highlights.append(.init(
                    id: "firstStamp",
                    kindRaw: "firstStamp",
                    countryCode: code,
                    countryName: name,
                    count: nil,
                    yearsLine: "\(year)"
                ))
            }
        }

        // Latest stamp (most recent photo by creation_ts with a country)
        do {
            let sql = """
            SELECT country_code, COALESCE(country_name, country_code) AS name, MAX(creation_ts) AS max_ts
            FROM photos
            WHERE country_code IS NOT NULL AND creation_ts IS NOT NULL
            GROUP BY country_code
            ORDER BY max_ts DESC
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                let code = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "??"
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? code
                let maxTs = sqlite3_column_double(stmt, 2)
                let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: maxTs))
                highlights.append(.init(
                    id: "latestStamp",
                    kindRaw: "latestStamp",
                    countryCode: code,
                    countryName: name,
                    count: nil,
                    yearsLine: "\(year)"
                ))
            }
        }

        // Ensure highlights are in a consistent order.
        let order = ["mostPhotographed", "firstStamp", "latestStamp"]
        highlights.sort { a, b in
            (order.firstIndex(of: a.kindRaw) ?? 999) < (order.firstIndex(of: b.kindRaw) ?? 999)
        }

        return CountryDiarySummary(countriesCount: countriesCount, dateRange: dateRange, highlights: highlights)
    }
}

enum SQLiteError: Error {
    case notOpen
    case openFailed(message: String)
    case execFailed(message: String)
    case prepareFailed(message: String)
    case stepFailed(message: String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
