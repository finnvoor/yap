import Speech

extension AssetInventory {
    /// Reserves `locale`, evicting the oldest reservation first if the reservation limit has been reached.
    static func reserveIfNeeded(locale: Locale) async throws {
        guard await !reservedLocales.contains(locale) else { return }

        while await reservedLocales.count >= maximumReservedLocales,
              let localeToRelease = await reservedLocales.first
        {
            await release(reservedLocale: localeToRelease)
        }
        try await reserve(locale: locale)
    }
}
