import Foundation

extension AISettingsSnapshot {
    /// Explicit allowlist. Newly added Trio fields are not automatically transmitted.
    init(settings: TrioSettings, preferences: Preferences, pump: PumpSettings, schedules: [AIScheduleEntry]) {
        self.settings = [
            AISetting(name: "units", value: String(describing: settings.units)),
            AISetting(name: "closedLoop", value: String(describing: settings.closedLoop)),
            AISetting(name: "smoothGlucose", value: String(describing: settings.smoothGlucose)),
            AISetting(name: "useFPUconversion", value: String(describing: settings.useFPUconversion)),
            AISetting(name: "individualAdjustmentFactor", value: String(describing: settings.individualAdjustmentFactor)),
            AISetting(name: "minuteInterval", value: String(describing: settings.minuteInterval)),
            AISetting(name: "delay", value: String(describing: settings.delay)),
            AISetting(name: "allowDilution", value: String(describing: settings.allowDilution)),
            AISetting(name: "insulinConcentration", value: String(describing: settings.insulinConcentration)),
            AISetting(name: "maxCarbs", value: String(describing: settings.maxCarbs)),
            AISetting(name: "maxFat", value: String(describing: settings.maxFat)),
            AISetting(name: "maxProtein", value: String(describing: settings.maxProtein)),
            AISetting(name: "overrideFactor", value: String(describing: settings.overrideFactor)),
            AISetting(name: "fattyMeals", value: String(describing: settings.fattyMeals)),
            AISetting(name: "fattyMealFactor", value: String(describing: settings.fattyMealFactor)),
            AISetting(name: "sweetMeals", value: String(describing: settings.sweetMeals)),
            AISetting(name: "sweetMealFactor", value: String(describing: settings.sweetMealFactor)),
            AISetting(name: "carbsRequiredThreshold", value: String(describing: settings.carbsRequiredThreshold))
        ]
        self.preferences = [
            AISetting(name: "maxIOB", value: String(describing: preferences.maxIOB)),
            AISetting(name: "maxDailySafetyMultiplier", value: String(describing: preferences.maxDailySafetyMultiplier)),
            AISetting(name: "currentBasalSafetyMultiplier", value: String(describing: preferences.currentBasalSafetyMultiplier)),
            AISetting(name: "autosensMax", value: String(describing: preferences.autosensMax)),
            AISetting(name: "autosensMin", value: String(describing: preferences.autosensMin)),
            AISetting(name: "smbDeliveryRatio", value: String(describing: preferences.smbDeliveryRatio)),
            AISetting(name: "rewindResetsAutosens", value: String(describing: preferences.rewindResetsAutosens)),
            AISetting(
                name: "highTemptargetRaisesSensitivity",
                value: String(describing: preferences.highTemptargetRaisesSensitivity)
            ),
            AISetting(
                name: "lowTemptargetLowersSensitivity",
                value: String(describing: preferences.lowTemptargetLowersSensitivity)
            ),
            AISetting(name: "sensitivityRaisesTarget", value: String(describing: preferences.sensitivityRaisesTarget)),
            AISetting(name: "resistanceLowersTarget", value: String(describing: preferences.resistanceLowersTarget)),
            AISetting(name: "advTargetAdjustments", value: String(describing: preferences.advTargetAdjustments)),
            AISetting(name: "exerciseMode", value: String(describing: preferences.exerciseMode)),
            AISetting(name: "halfBasalExerciseTarget", value: String(describing: preferences.halfBasalExerciseTarget)),
            AISetting(name: "maxCOB", value: String(describing: preferences.maxCOB)),
            AISetting(name: "maxMealAbsorptionTime", value: String(describing: preferences.maxMealAbsorptionTime)),
            AISetting(name: "wideBGTargetRange", value: String(describing: preferences.wideBGTargetRange)),
            AISetting(name: "skipNeutralTemps", value: String(describing: preferences.skipNeutralTemps)),
            AISetting(name: "unsuspendIfNoTemp", value: String(describing: preferences.unsuspendIfNoTemp)),
            AISetting(name: "min5mCarbimpact", value: String(describing: preferences.min5mCarbimpact)),
            AISetting(name: "remainingCarbsFraction", value: String(describing: preferences.remainingCarbsFraction)),
            AISetting(name: "remainingCarbsCap", value: String(describing: preferences.remainingCarbsCap)),
            AISetting(name: "enableUAM", value: String(describing: preferences.enableUAM)),
            AISetting(name: "a52RiskEnable", value: String(describing: preferences.a52RiskEnable)),
            AISetting(name: "enableSMBWithCOB", value: String(describing: preferences.enableSMBWithCOB)),
            AISetting(name: "enableSMBWithTemptarget", value: String(describing: preferences.enableSMBWithTemptarget)),
            AISetting(name: "enableSMBAlways", value: String(describing: preferences.enableSMBAlways)),
            AISetting(name: "enableSMBAfterCarbs", value: String(describing: preferences.enableSMBAfterCarbs)),
            AISetting(name: "allowSMBWithHighTemptarget", value: String(describing: preferences.allowSMBWithHighTemptarget)),
            AISetting(name: "maxSMBBasalMinutes", value: String(describing: preferences.maxSMBBasalMinutes)),
            AISetting(name: "maxUAMSMBBasalMinutes", value: String(describing: preferences.maxUAMSMBBasalMinutes)),
            AISetting(name: "smbInterval", value: String(describing: preferences.smbInterval)),
            AISetting(name: "bolusIncrement", value: String(describing: preferences.bolusIncrement)),
            AISetting(name: "curve", value: String(describing: preferences.curve)),
            AISetting(name: "useCustomPeakTime", value: String(describing: preferences.useCustomPeakTime)),
            AISetting(name: "insulinPeakTime", value: String(describing: preferences.insulinPeakTime)),
            AISetting(name: "carbsReqThreshold", value: String(describing: preferences.carbsReqThreshold)),
            AISetting(name: "noisyCGMTargetMultiplier", value: String(describing: preferences.noisyCGMTargetMultiplier)),
            AISetting(name: "suspendZerosIOB", value: String(describing: preferences.suspendZerosIOB)),
            AISetting(name: "maxDeltaBGthreshold", value: String(describing: preferences.maxDeltaBGthreshold)),
            AISetting(name: "adjustmentFactor", value: String(describing: preferences.adjustmentFactor)),
            AISetting(name: "adjustmentFactorSigmoid", value: String(describing: preferences.adjustmentFactorSigmoid)),
            AISetting(name: "sigmoid", value: String(describing: preferences.sigmoid)),
            AISetting(name: "useNewFormula", value: String(describing: preferences.useNewFormula)),
            AISetting(name: "useWeightedAverage", value: String(describing: preferences.useWeightedAverage)),
            AISetting(name: "weightPercentage", value: String(describing: preferences.weightPercentage)),
            AISetting(name: "tddAdjBasal", value: String(describing: preferences.tddAdjBasal)),
            AISetting(name: "enableSMB_high_bg", value: String(describing: preferences.enableSMB_high_bg)),
            AISetting(name: "enableSMB_high_bg_target", value: String(describing: preferences.enableSMB_high_bg_target)),
            AISetting(name: "threshold_setting", value: String(describing: preferences.threshold_setting)),
            AISetting(name: "updateInterval", value: String(describing: preferences.updateInterval))
        ]
        pumpSettings = [
            AISetting(name: "insulinActionCurveHours", value: String(describing: pump.insulinActionCurve)),
            AISetting(name: "maxBolusUnits", value: String(describing: pump.maxBolus)),
            AISetting(name: "maxBasalUnitsPerHour", value: String(describing: pump.maxBasal))
        ]
        self.schedules = schedules
    }
}
