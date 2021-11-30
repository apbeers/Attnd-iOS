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
                    Image(systemName: "map.fill")
                    Text("Map")
                }
            LocationsView()
                .tabItem {
                    Image(systemName: "map.fill")
                    Text("Locations")
                }
            FlyerView()
                .tabItem {
                    Image(systemName: "page.fill")
                    Text("Flyer")
                }
            NotificationsView()
                .tabItem {
                    Image(systemName: "notification.fill")
                    Text("Notifications")
                }
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
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
