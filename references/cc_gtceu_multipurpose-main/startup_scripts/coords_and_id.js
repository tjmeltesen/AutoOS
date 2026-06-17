// priority: 0

function getCoords (block) {
    if (!block) return null;
    return { x: block.pos.x, y: block.pos.y, z: block.pos.z }
}

function getBlockId (block) {
    if (!block) return null;
    return block.id
}

ComputerCraftEvents.peripheral(event => {
    // everything
    event.registerPeripheral("everything", /^.*$/)
        .mainThreadMethod("getCoords", getCoords)
        .mainThreadMethod("getBlockId", getBlockId)
})