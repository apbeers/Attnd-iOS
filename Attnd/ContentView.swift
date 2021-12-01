//
//  ContentView.swift
//  Attnd
//
//  Created by Andrew Beers on 4/9/21.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            
            MapView()
                .tabItem {
                    Image(systemName: "map")
                    Text("Map")
                }
            LocationsView()
                .tabItem {
                    Image(systemName: "list.dash")
                    Text("Locations")
                }
            FlyerView()
                .tabItem {
                    Image(systemName: "doc")
                    Text("Flyer")
                }
            NotificationsView()
                .tabItem {
                    Image(systemName: "bell")
                    Text("Notifications")
                }
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape")
                    Text("Settings")
                }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
