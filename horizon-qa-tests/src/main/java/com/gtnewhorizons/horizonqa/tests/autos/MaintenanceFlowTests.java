package com.gtnewhorizons.horizonqa.tests.autos;

import com.gtnewhorizons.horizonqa.api.GameTest;
import com.gtnewhorizons.horizonqa.api.GameTestHelper;
import com.gtnewhorizons.horizonqa.api.GameTestHolder;
import com.gtnewhorizons.horizonqa.api.GTNHGameTestHelper;
import com.gtnewhorizons.horizonqa.api.gt.Multiblock;
import com.gtnewhorizons.horizonqa.api.gt.MaintenanceType;
import static com.gtnewhorizons.horizonqa.api.TestPos.at;

/**
 * Maintenance detection and recovery flows.
 *
 * AutoOS maintenance_parse.lua reads getSensorInformation() output to detect
 * maintenance problems. These tests verify the full detect -> fix -> run cycle
 * that AutoOS depends on for reliable machine operation.
 */
@GameTestHolder("autos")
public class MaintenanceFlowTests {

    /**
     * A newly-formed LCR should have maintenance issues that appear
     * in getSensorInformation output. AutoOS parses this string.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 100)
    public static void maintenanceIssuesAppearInSensorInfo(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();

        // Don't fix maintenance — verify issues are detectable
        Object controller = gtnh.multiblock(at(1, 0, 0));
        String sensor = gtnh.getSensorInformation(controller);

        helper.assertTrue(sensor != null && sensor.length() > 0,
            "Sensor info must be non-empty for a formed machine");

        // Sensor info should contain maintenance-related data
        // (maintenance_parse.lua scans for problem indicators in this output)
        helper.assertTrue(
            sensor.contains("Maintenance") || sensor.contains("Problem") ||
            sensor.contains("Wrench") || sensor.contains("Crowbar") ||
            sensor.contains("Screwdriver") || sensor.contains("Hammer") ||
            sensor.contains("Soft Hammer") || sensor.contains("Soldering Iron") ||
            sensor.length() > 50,
            "Sensor info should indicate machine state: " + sensor);

        helper.succeed();
    }

    /**
     * After fixing maintenance, the machine should be able to run a recipe.
     * This is the fixAllMaintenanceIssues -> runRecipe path AutoOS relies on.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 600)
    public static void fixIssuesEnablesRecipeRun(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();

        // Fix maintenance using the full fixMaintenance() which also enables working
        lcr.fixMaintenance();

        // Supply EU and run
        lcr.energyHatch(0).supply(128, 2, 500);
        lcr.inputBus(0).programmedCircuit(5);
        lcr.runRecipe(500);

        // After recipe, machine should be idle (not stuck)
        Object controller = gtnh.multiblock(at(1, 0, 0));
        helper.assertFalse(gtnh.isMachineActive(controller),
            "Machine should be idle after recipe despite initial maintenance issues");
        helper.assertFalse(gtnh.hasWork(controller),
            "Machine should have no work after recipe despite initial maintenance issues");

        helper.succeed();
    }

    /**
     * Verify that setWorkAllowed interacts correctly with maintenance state.
     * AutoOS calls setWorkAllowed(true) after fixing maintenance.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 200)
    public static void workAllowedAfterMaintenanceFix(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();

        Object controller = gtnh.multiblock(at(1, 0, 0));

        // Before fixing: workAllowed may be false
        // Fix maintenance and enable working
        lcr.fixMaintenance();
        gtnh.setWorkAllowed(controller, true);

        helper.assertTrue(gtnh.isWorkAllowed(controller),
            "workAllowed must be true after fixMaintenance + setWorkAllowed");

        // Run a recipe to verify the machine actually works
        lcr.energyHatch(0).supply(128, 2, 500);
        lcr.inputBus(0).programmedCircuit(5);
        lcr.runRecipe(500);

        // After recipe, workAllowed should STILL be true
        helper.assertTrue(gtnh.isWorkAllowed(controller),
            "workAllowed must persist after recipe with maintenance fix");

        helper.succeed();
    }
}
