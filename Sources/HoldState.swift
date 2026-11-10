struct HoldState<Owner: Equatable, Destination> {
    private(set) var active: (owner: Owner, destination: Destination)?

    mutating func begin(owner: Owner, destination: Destination) -> Bool {
        guard active == nil else { return false }
        active = (owner, destination)
        return true
    }

    mutating func end(owner: Owner? = nil) -> Destination? {
        guard let current = active, owner == nil || owner == current.owner else { return nil }
        active = nil
        return current.destination
    }
}
