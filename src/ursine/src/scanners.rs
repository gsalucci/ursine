//! Scanners screen: SANE discovery and manual airscan setup.

use crate::prelude::*;
use ursine_api::ScannerConfigView;

use crate::package_ui::{text_row, ConfirmVm};

#[derive(Default)]
pub struct ScannersState {
    pub view: Option<ScannerConfigView>,
    pub busy: bool,
    pub action_busy: bool,
    pub error: Option<String>,
    pub message: Option<String>,
    pub name: String,
    pub address: String,
    pub protocol: usize,
    pub pending_remove: Option<String>,
}

impl ScannersState {
    pub fn apply(&mut self, view: ScannerConfigView) {
        self.view = Some(view);
        self.error = None;
    }

    pub fn view(&self) -> Element<'_, Message> {
        let mut items = vec![ui::header(
            "Scanners",
            (!self.busy && !self.action_busy).then_some(Message::RefreshScanners),
        )];
        items.extend(ui::status(
            self.error.as_ref(),
            self.message.as_ref().map(|_| "Saved."),
            self.busy.then_some("Discovering scanners…"),
            self.action_busy.then_some("Writing airscan config…"),
        ));

        if let Some(view) = &self.view {
            items.push(
                settings::section()
                    .title("airscan configuration")
                    .add(settings::item("Path", text(view.path.clone())))
                    .add(settings::item(
                        "Discovery",
                        toggler(!view.discovery_disabled)
                            .on_toggle(Message::ScannerDiscoveryToggled),
                    ))
                    .add(settings::item(
                        "Detection",
                        if view.detected.is_empty() {
                            Element::from(text("No scanners detected by scanimage -L."))
                        } else {
                            Element::from(text(format!("{} detected", view.detected.len())))
                        },
                    ))
                    .into(),
            );

            let mut detected = settings::section().title("Detected devices");
            if view.detected.is_empty() {
                detected = detected.add(settings::item("Result", text("None.")));
            }
            for scanner in &view.detected {
                detected = detected.add(settings::item(
                    scanner.id.clone(),
                    text(scanner.description.clone()),
                ));
            }
            items.push(detected.into());

            let mut manual = settings::section().title("Manual airscan devices");
            if view.devices.is_empty() {
                manual = manual.add(settings::item("Result", text("None configured.")));
            }
            for device in &view.devices {
                let name = device.name.clone();
                manual = manual.add(settings::item(
                    format!("{} — {} ({})", device.name, device.address, device.protocol),
                    button::destructive("Remove…").on_press(Message::ScannerRemoveRequested(name)),
                ));
            }
            items.push(manual.into());

            items.push(
                settings::section()
                    .title("Add or update manual device")
                    .add(settings::item(
                        "Name",
                        text_input("Brother MFC-1910W", self.name.clone())
                            .on_input(Message::ScannerNameChanged),
                    ))
                    .add(settings::item(
                        "Address",
                        text_input(
                            "http://192.168.1.2:80/WebServices/ScannerService",
                            self.address.clone(),
                        )
                        .on_input(Message::ScannerAddressChanged),
                    ))
                    .add(settings::item(
                        "Protocol",
                        dropdown(
                            vec!["WSD", "eSCL"],
                            Some(self.protocol.min(1)),
                            Message::ScannerProtocolChanged,
                        ),
                    ))
                    .add(settings::item(
                        "Save",
                        button::suggested("Save device").on_press_maybe(
                            (!self.action_busy).then_some(Message::ScannerSaveRequested),
                        ),
                    ))
                    .into(),
            );
        }

        scrollable(column(items).spacing(16).padding(24)).into()
    }
}

impl ScannersState {
    /// Pending removal confirmation as modal data.
    pub(crate) fn pending_confirm(&self) -> Option<ConfirmVm<'_>> {
        let name = self.pending_remove.as_ref()?;
        Some(ConfirmVm {
            title: "Confirm scanner removal".to_string(),
            rows: vec![(
                "Consequences".to_string(),
                text_row(format!("Remove manual airscan device {name}?")),
            )],
            confirm: Message::ScannerRemoveConfirmed,
            cancel: Message::ScannerRemoveCancelled,
            armed: !self.action_busy,
            destructive: true,
        })
    }
}
