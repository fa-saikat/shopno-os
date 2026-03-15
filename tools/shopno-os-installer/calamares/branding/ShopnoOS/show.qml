/* === This file is part of Calamares - <http://github.com/calamares> ===
 *
 *   Copyright 2015, Teo Mrnjavac <teo@kde.org>
 *
 *   Calamares is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   Calamares is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with Calamares. If not, see <http://www.gnu.org/licenses/>.
 *
 *   ShopnoOS custom settings
 */

import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    Timer {
        id: advanceTimer
        interval: 30000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        anchors.fill: parent
        anchors.verticalCenterOffset: 0

        Image {
            id: background1
            source: "slide-1.png"
            width: parent.width; height: parent.height
            horizontalAlignment: Image.AlignCenter
            verticalAlignment: Image.AlignTop

            anchors.fill: parent

            Text {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: 165
                anchors.horizontalCenterOffset: 0
                font.pixelSize: parent.width *.020
                color: 'white'
                text: qsTr("<b>Welcome to ShopnoOS, a Debian based Linux distribution<br/>")
                wrapMode: Text.WordWrap
                width: parent.width / 1.4
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    Slide {
        anchors.fill: parent
        anchors.verticalCenterOffset: 0

        Image {
            id: background2
            source: "slide-2.png"
            width: parent.width; height: parent.height
            horizontalAlignment: Image.AlignCenter
            verticalAlignment: Image.AlignTop

            anchors.fill: parent

            Text {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: 163
                anchors.horizontalCenterOffset: 0
                font.pixelSize: parent.width *.020
                color: 'white'
                text: qsTr("<b>ShopnoOS is 100% compatible with JaduPc Hardware<br/>")

                wrapMode: Text.WordWrap
                width: parent.width / 1.4
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    Slide {
        anchors.fill: parent
        anchors.verticalCenterOffset: 0

        Image {
            id: background3
            source: "slide-3.png"
            width: parent.width; height: parent.height
            horizontalAlignment: Image.AlignCenter
            verticalAlignment: Image.AlignTop

            anchors.fill: parent

            Text {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: 165
                anchors.horizontalCenterOffset: 0
                font.pixelSize: parent.width *.020
                color: 'white'
                text: qsTr("<b>Visit official website for documentation<br/>")
                wrapMode: Text.WordWrap
                width: parent.width / 1.4
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    // Slide {
    //     anchors.fill: parent
    //     anchors.verticalCenterOffset: 0
    //
    //     Image {
    //         id: background4
    //         source: "dev.png"
    //         width: parent.width; height: parent.height
    //         horizontalAlignment: Image.AlignCenter
    //         verticalAlignment: Image.AlignTop
    //
    //         anchors.fill: parent
    //
    //         Text {
    //             anchors.centerIn: parent
    //             anchors.verticalCenterOffset: 165
    //             anchors.horizontalCenterOffset: 0
    //             font.pixelSize: parent.width *.020
    //             color: 'white'
    //             text: qsTr("<b>ShopnoOS is built for developers<br/>")
    //             wrapMode: Text.WordWrap
    //             width: parent.width / 1.4
    //             horizontalAlignment: Text.AlignHCenter
    //         }
    //
    //         Text {
    //             anchors.centerIn: parent
    //             anchors.verticalCenterOffset: 165
    //             anchors.horizontalCenterOffset: 0
    //             font.pixelSize: parent.width *.020
    //             color: 'white'
    //             text: qsTr("<b>Web • Python • C/C++ • Embedded Systems<br/>")
    //             wrapMode: Text.WordWrap
    //             width: parent.width / 1.5
    //             horizontalAlignment: Text.AlignHCenter
    //         }
    //
    //         Text {
    //             anchors.centerIn: parent
    //             anchors.verticalCenterOffset: 165
    //             anchors.horizontalCenterOffset: 0
    //             font.pixelSize: parent.width *.020
    //             color: 'white'
    //             text: qsTr("<b>Optimized toolchain • Hardware acceleration • Lightweight base<br/>")
    //             wrapMode: Text.WordWrap
    //             width: parent.width / 1.5
    //             horizontalAlignment: Text.AlignHCenter
    //         }
    //     }
    // }
    //
    // Slide {
    //     anchors.fill: parent
    //     anchors.verticalCenterOffset: 0
    //
    //     Image {
    //         id: background5
    //         source: "media.png"
    //         width: parent.width; height: parent.height
    //         horizontalAlignment: Image.AlignCenter
    //         verticalAlignment: Image.AlignTop
    //
    //         anchors.fill: parent
    //
    //         Text {
    //             anchors.centerIn: parent
    //             anchors.verticalCenterOffset: 165
    //             anchors.horizontalCenterOffset: 0
    //             font.pixelSize: parent.width *.020
    //             color: 'white'
    //             text: qsTr("<b>ShopnoOS offers smooth media experience<br/>")
    //             wrapMode: Text.WordWrap
    //             width: parent.width / 1.4
    //             horizontalAlignment: Text.AlignHCenter
    //         }
    //
    //         Text {
    //             anchors.centerIn: parent
    //             anchors.verticalCenterOffset: 165
    //             anchors.horizontalCenterOffset: 0
    //             font.pixelSize: parent.width *.020
    //             color: 'white'
    //             text: qsTr("<b>Documents • Sheets • Presentations • PDF<br/>")
    //             wrapMode: Text.WordWrap
    //             width: parent.width / 1.5
    //             horizontalAlignment: Text.AlignHCenter
    //         }
    //
    //         Text {
    //             anchors.centerIn: parent
    //             anchors.verticalCenterOffset: 165
    //             anchors.horizontalCenterOffset: 0
    //             font.pixelSize: parent.width *.020
    //             color: 'white'
    //             text: qsTr("<b>Clean Desktop • Windows-like Layout • Beginner Friendly<br/>")
    //             wrapMode: Text.WordWrap
    //             width: parent.width / 1.5
    //             horizontalAlignment: Text.AlignHCenter
    //         }
    //
    //         Text {
    //             anchors.centerIn: parent
    //             anchors.verticalCenterOffset: 165
    //             anchors.horizontalCenterOffset: 0
    //             font.pixelSize: parent.width *.020
    //             color: 'white'
    //             text: qsTr("<b>Ideal for Education, Offices and Home Use<br/>")
    //             wrapMode: Text.WordWrap
    //             width: parent.width / 1.5
    //             horizontalAlignment: Text.AlignHCenter
    //         }
    //     }
    // }
    //
    // Slide {
    //     anchors.fill: parent
    //     anchors.verticalCenterOffset: 0
    //
    //     Image {
    //         id: background6
    //         source: "office.png"
    //         width: parent.width; height: parent.height
    //         horizontalAlignment: Image.AlignCenter
    //         verticalAlignment: Image.AlignTop
    //
    //         anchors.fill: parent
    //
    //         Text {
    //             anchors.centerIn: parent
    //             anchors.verticalCenterOffset: 165
    //             anchors.horizontalCenterOffset: 0
    //             font.pixelSize: parent.width *.020
    //             color: 'white'
    //             text: qsTr("<b>ShopnoOS is work-ready<br/>")
    //             wrapMode: Text.WordWrap
    //             width: parent.width / 1.4
    //             horizontalAlignment: Text.AlignHCenter
    //         }
    //     }
    // }

    Slide {
        anchors.fill: parent
        anchors.verticalCenterOffset: 0

        Image {
            id: background7
            source: "slide-1.png"
            width: parent.width; height: parent.height
            horizontalAlignment: Image.AlignCenter
            verticalAlignment: Image.AlignTop

            anchors.fill: parent

            Text {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: 165
                anchors.horizontalCenterOffset: 0
                font.pixelSize: parent.width *.020
                color: 'white'
                text: qsTr("<b>Thank you for trying ShopnoOS<br/>")
                wrapMode: Text.WordWrap
                width: parent.width / 1.4
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    Component.onCompleted: advanceTimer.running = true
}

