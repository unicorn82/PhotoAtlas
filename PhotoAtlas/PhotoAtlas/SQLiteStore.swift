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
    }

    func resetAll() throws {
        guard let db = db else { throw SQLiteError.notOpen }
        if sqlite3_exec(db, "DELETE FROM photos;", nil, nil, nil) != SQLITE_OK {
            throw SQLiteError.execFailed(message: String(cString: sqlite3_errmsg(db)))
        }
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

    func photoIds(inCluster clusterKey: String, precision: ClusterPrecision) throws -> [(localId: String, creationTs: Double?)] {
        guard let db = db else { throw SQLiteError.notOpen }

        let sql: String
        let bindings: [String]

        switch precision {
        case .country:
            // clusterKey: country:US
            let code = clusterKey.replacingOccurrences(of: "country:", with: "")
            sql = """
            SELECT local_id, creation_ts
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
            SELECT local_id, creation_ts
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

        var rows: [(String, Double?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let creation: Double?
            if sqlite3_column_type(stmt, 1) == SQLITE_NULL { creation = nil }
            else { creation = sqlite3_column_double(stmt, 1) }
            rows.append((id, creation))
        }
        return rows
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
}

enum SQLiteError: Error {
    case notOpen
    case openFailed(message: String)
    case execFailed(message: String)
    case prepareFailed(message: String)
    case stepFailed(message: String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
