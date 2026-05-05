SERNUM = "9D321450B9B64C3B"

from saleae import automation

with automation.Manager.connect(port=10430) as manager:
    device_configuration = automation.LogicDeviceConfiguration(
        enabled_digital_channels=[0, 1, 2, 3, 4, 5, 6, 7],
        digital_sample_rate=24_000_000,
    )

    capture_configuration = automation.CaptureConfiguration(
        capture_mode=automation.DigitalTriggerCaptureMode(
            trigger_type=automation.DigitalTriggerType.RISING,
            trigger_channel_index=3,
            trim_data_seconds=0.5,
            after_trigger_seconds=5,
        )
    )

    with manager.start_capture(
        device_id=SERNUM,
        device_configuration=device_configuration,
        capture_configuration=capture_configuration,
    ) as capture:
        # capture.wait()
        pass
