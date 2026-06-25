package autos;

import com.gtnewhorizons.horizonqa.api.GameTest;
import com.gtnewhorizons.horizonqa.api.GameTestHelper;
import com.gtnewhorizons.horizonqa.api.GameTestHolder;
import com.gtnewhorizons.horizonqa.api.GTNHGameTestHelper;
import static com.gtnewhorizons.horizonqa.api.TestPos.at;

/**
 * Validates transposer API behavior that AutoOS depends on
 * for item/fluid transfer between ME interface and machine bus/hatch.
 */
@GameTestHolder("autos")
public class TransposerTests {

    /**
     * Verify getStackInSlot returns items placed in the transposer.
     * AutoOS uses this to find integrated circuits and verify item transfers.
     */
    @GameTest(template = "transposer_chest", timeoutTicks = 40)
    public static void getStackInSlotWorks(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object tp = gtnh.block(at(0, 0, 0));
        // Place a stack in slot 1, side 0
        gtnh.setSlot(tp, 0, 1, "minecraft:stone", 64);
        Object stack = gtnh.getStackInSlot(tp, 0, 1);
        helper.assertTrue(stack != null, "getStackInSlot returned null");
        helper.succeed();
    }

    /**
     * Verify transferItem moves items between sides.
     * AutoOS uses this to move items from interface buffer to machine input bus.
     */
    @GameTest(template = "transposer_chest", timeoutTicks = 40)
    public static void transferItemWorks(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object tp = gtnh.block(at(0, 0, 0));
        gtnh.setSlot(tp, 0, 1, "minecraft:stone", 64);
        int moved = gtnh.transferItem(tp, 0, 1, 1, 1, 1);
        helper.assertTrue(moved > 0, "transferItem should move at least 1 item");
        helper.succeed();
    }

    /**
     * Verify getTankLevel returns data on valid fluid faces.
     * AutoOS uses this to verify fluid hatch contents during lane stocking.
     */
    @GameTest(template = "transposer_tank", timeoutTicks = 40)
    public static void getTankLevelOnValidFace(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object tp = gtnh.block(at(0, 0, 0));
        // Fill tank side with water
        gtnh.fillTank(tp, 1, "water", 1000);
        Object tank = gtnh.getTankLevel(tp, 1);
        helper.assertTrue(tank != null, "getTankLevel should return data on valid fluid face");
        helper.succeed();
    }

    /**
     * Verify getInventorySize returns sensible values.
     * AutoOS uses this to scan for circuits across transposer faces.
     */
    @GameTest(template = "transposer_chest", timeoutTicks = 20)
    public static void getInventorySizeWorks(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object tp = gtnh.block(at(0, 0, 0));
        int size = gtnh.getInventorySize(tp, 0);
        helper.assertTrue(size > 0, "getInventorySize should be >0 for valid item side");
        helper.succeed();
    }
}
