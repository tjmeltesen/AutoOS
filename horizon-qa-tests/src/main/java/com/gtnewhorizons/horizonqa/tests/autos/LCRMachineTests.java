package com.gtnewhorizons.horizonqa.tests.autos;

import com.gtnewhorizons.horizonqa.api.GameTest;
import com.gtnewhorizons.horizonqa.api.GameTestHelper;
import com.gtnewhorizons.horizonqa.api.GameTestHolder;
import com.gtnewhorizons.horizonqa.api.GTNHGameTestHelper;
import static com.gtnewhorizons.horizonqa.api.TestPos.at;

/**
 * Validates LCR (Large Chemical Reactor) machine API behavior
 * that AutoOS broker depends on for lane dispatch and completion detection.
 */
@GameTestHolder("autos")
public class LCRMachineTests {

    /**
     * Verify getSensorInformation returns non-null string for a formed LCR.
     * AutoOS uses this to parse maintenance faults via maintenance_parse.lua.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 100)
    public static void sensorInfoReturnsData(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object machine = gtnh.multiblock(at(1, 0, 0));
        String sensor = gtnh.getSensorInformation(machine);
        helper.assertTrue(sensor != null, "getSensorInformation returned null");
        helper.assertTrue(sensor.length() > 0, "getSensorInformation returned empty string");
        helper.succeed();
    }

    /**
     * Verify isWorkAllowed persists after being set.
     * AutoOS calls setWorkAllowed(true) on machine start and expects it to stick.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 100)
    public static void workAllowedPersists(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object machine = gtnh.multiblock(at(1, 0, 0));
        gtnh.setWorkAllowed(machine, true);
        helper.onEachTick(() ->
            helper.assertTrue(gtnh.isWorkAllowed(machine), "workAllowed reset unexpectedly"));
        helper.succeedAtTimeout();
    }

    /**
     * Verify isMachineActive returns correctly for idle machine.
     * AutoOS uses this in completion detection to know when a job is done.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 40)
    public static void idleMachineNotActive(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object machine = gtnh.multiblock(at(1, 0, 0));
        boolean active = gtnh.isMachineActive(machine);
        helper.assertFalse(active, "Idle machine should not be active");
        helper.succeed();
    }

    /**
     * Verify hasWork returns false for idle machine with no recipe.
     * AutoOS uses hasWork as a completion signal.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 40)
    public static void idleMachineHasNoWork(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Object machine = gtnh.multiblock(at(1, 0, 0));
        boolean hasWork = gtnh.hasWork(machine);
        helper.assertFalse(hasWork, "Idle machine should not have work");
        helper.succeed();
    }
}
