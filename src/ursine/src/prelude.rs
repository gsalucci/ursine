//! Shared widget prelude for the screen modules: one widget set, one `Message`.

#![allow(clippy::redundant_pub_crate)] // private module: pub(crate) is the real visibility

pub(crate) use cosmic::iced::Length;
pub(crate) use cosmic::widget::selectable_text;
pub(crate) use cosmic::widget::{
    button, column, container, dropdown, row, scrollable, settings, text, text_input, toggler,
};
pub(crate) use cosmic::Element;

pub(crate) use crate::app::Message;
pub(crate) use crate::ui;
