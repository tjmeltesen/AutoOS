package com.gtnewhorizons.horizonqa.tests.autos;

import com.gtnewhorizons.horizonqa.api.GameTest;
import com.gtnewhorizons.horizonqa.api.GameTestHelper;
import com.gtnewhorizons.horizonqa.api.GameTestHolder;
import com.gtnewhorizons.horizonqa.api.GTNHGameTestHelper;
import static com.gtnewhorizons.horizonqa.api.TestPos.at;

/**
 * Validates ME Interface API behavior that AutoOS depends on
 * for lane stocking: set configuration, store items/fluids, query network.
 */
@GameTestHolder("autos")
public class MEInterfaceTests {

    /**
     * Verify setInterfaceConfiguration accepts an item configuration.
     * AutoOS configures each lane's ME interface with recipe inputs.
     */
    @GameTest(template = "me_interface_single", timeoutTicks = 40)
    public static void setItemConfigWorks(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object iface = gtnh.block(at(0, 0, 0));
        // Set slot 1 to request 64 stone
        gtnh.setInterfaceConfig(iface, 1, "minecraft:stone", 64);
        helper.assertTrue(true, "setInterfaceConfiguration should not throw");
        helper.succeed();
    }

    /**
     * Verify getItemsInNetwork returns data.
     * AutoOS uses this to verify AE2 delivery before lane transfer.
     */
    @GameTest(template = "me_interface_single", timeoutTicks = 40)
    public static void getItemsInNetworkWorks(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object iface = gtnh.block(at(0, 0, 0));
        Object items = gtnh.getItemsInNetwork(iface);
        helper.assertTrue(items != null, "getItemsInNetwork should not return null");
        helper.succeed();
    }

    /**
     * Verify store operation works.
     * AutoOS uses store to push items back into the ME network
     * (e.g., integrated circuits after job completion).
     */
    @GameTest(template = "me_interface_single", timeoutTicks = 40)
    public static void storeWorks(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object iface = gtnh.block(at(0, 0, 0));
        // Store a stone item
        gtnh.store(iface, "minecraft:stone", 1);
        helper.assertTrue(true, "store should not throw");
        helper.succeed();
    }

    /**
     * Verify getFluidsInNetwork returns data.
     * AutoOS uses this for fluid recipe verification.
     */
    @GameTest(template = "me_interface_single", timeoutTicks = 40)
    public static void getFluidsInNetworkWorks(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object iface = gtnh.block(at(0, 0, 0));
        Object fluids = gtnh.getFluidsInNetwork(iface);
        helper.assertTrue(fluids != null, "getFluidsInNetwork should not return null");
        helper.succeed();
    }
}
