//
//  SettingsView.swift
//  Attnd
//
//  Created by Andrew Beers on 11/29/21.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Event")) {
                    Toggle(isOn: .constant(true),
                           label: {
                            Text("Event Code")

                    })
                }
            }.navigationTitle("Settings")
        }
        
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
