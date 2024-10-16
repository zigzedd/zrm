const std = @import("std");

pub const ZrmError = error {
	QueryFailed,
	UnsupportedTableType,
	AtLeastOneValueRequired,
	AtLeastOneConditionRequired,
	AtLeastOneSelectionRequired,
	UpdatedValuesRequired,
};
