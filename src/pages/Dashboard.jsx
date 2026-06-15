import React, { useState, useEffect, useMemo } from 'react';
import { useSearchParams } from 'react-router-dom';
import LeftFilterPanel from '../components/LeftFilterPanel';
import MapArea from '../components/MapArea';
import StatusBar from '../components/StatusBar';
import RightDrawer from '../components/RightDrawer';
import TableView from '../components/TableView';
import { fetchInferredLanes, fetchTrips } from '../firebase';
import { processDefectData } from '../utils/dataProcessor';

const Dashboard = () => {
  const [searchParams] = useSearchParams();
  const [isLeftPanelCollapsed, setIsLeftPanelCollapsed] = useState(false);
  const [isRightDrawerOpen, setIsRightDrawerOpen] = useState(false);
  const [selectedDefect, setSelectedDefect] = useState(null);
  
  // Data Fetching State
  const [rawPoints, setRawPoints] = useState([]);
  const [tripSegments, setTripSegments] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [lastUpdated, setLastUpdated] = useState(new Date());

  // 'map' or 'table'
  const [viewMode, setViewMode] = useState(() => {
    return searchParams.get('view') === 'table' ? 'table' : 'map';
  });

  const handleDefectClick = (defect) => {
    setSelectedDefect(defect);
    setIsRightDrawerOpen(true);
  };

  const handleViewModeToggle = () => {
    const newMode = viewMode === 'map' ? 'table' : 'map';
    setViewMode(newMode);
    
    // Sync to URL
    const params = new URLSearchParams(window.location.search);
    if (newMode === 'table') params.set('view', 'table');
    else params.delete('view');
    window.history.replaceState({}, '', `${window.location.pathname}?${params}`);
  };

  // 1. Fetch data on mount
  const loadData = async () => {
    setLoading(true);
    setError(null);
    try {
      const [lanes, trips] = await Promise.all([
        fetchInferredLanes(),
        fetchTrips()
      ]);
      
      const { points, lineSegments } = processDefectData(lanes, trips);
      setRawPoints(points);
      setTripSegments(lineSegments);
      setLastUpdated(new Date());
    } catch (err) {
      console.error("Failed to load Firebase data:", err);
      setError("Failed to connect to Firebase database.");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    loadData();
  }, []);

  // 2. Filter data dynamically using URL Search Params
  const filteredPoints = useMemo(() => {
    // Extracted filter parameters with safe fallbacks matching LeftFilterPanel defaults
    const allowedTypes = searchParams.getAll('type');
    const types = allowedTypes.length ? allowedTypes : ['Potholes', 'Speed bumps', 'Manholes', 'Rough patches'];
    
    const allowedSeverities = searchParams.getAll('sev');
    const severities = allowedSeverities.length ? allowedSeverities : ['Mild', 'Moderate', 'Severe'];
    
    const minConfidence = parseInt(searchParams.get('conf') || '60', 10);
    const minReports = parseInt(searchParams.get('rep') || '3', 10);
    
    const allowedVehicles = searchParams.getAll('veh');
    const vehicles = allowedVehicles.length ? allowedVehicles : ['Sedan', 'SUV', 'Truck', 'Motorcycle', 'Mixed'];

    const startDate = searchParams.get('start') || '';
    const endDate = searchParams.get('end') || '';

    return rawPoints.filter(pt => {
      // Filter by Type
      if (!types.includes(pt.type)) return false;

      // Filter by Severity
      if (!severities.includes(pt.severity)) return false;

      // Filter by Confidence
      if (pt.confidence < minConfidence) return false;

      // Filter by Min Reports
      if (pt.reports < minReports) return false;

      // Filter by Vehicle Type
      if (vehicles.length > 0 && !vehicles.includes('Mixed') && !vehicles.includes(pt.vehicle)) return false;

      // Filter by Date Range
      if (startDate && pt.date < startDate) return false;
      if (endDate && pt.date > endDate) return false;

      return true;
    });
  }, [rawPoints, searchParams]);

  // Filter trip segments by Date Range
  const filteredTripSegments = useMemo(() => {
    const startDate = searchParams.get('start') || '';
    const endDate = searchParams.get('end') || '';

    return tripSegments.filter(segment => {
      const segDate = segment.properties.date;
      if (!segDate) return true;
      if (startDate && segDate < startDate) return false;
      if (endDate && segDate > endDate) return false;
      return true;
    });
  }, [tripSegments, searchParams]);

  return (
    <>
      <div className="main-content">
        <LeftFilterPanel 
          isCollapsed={isLeftPanelCollapsed} 
          setIsCollapsed={setIsLeftPanelCollapsed} 
        />
        
        {loading ? (
          <div className="loading-state-overlay glass">
            <div className="spinner"></div>
            <span>Connecting to Firestore database...</span>
          </div>
        ) : error ? (
          <div className="error-state-overlay glass">
            <p className="error-text">{error}</p>
            <button className="primary-btn" onClick={loadData}>Retry</button>
          </div>
        ) : viewMode === 'map' ? (
          <MapArea 
            onDefectClick={handleDefectClick}
            isLeftPanelCollapsed={isLeftPanelCollapsed}
            points={filteredPoints}
            tripSegments={filteredTripSegments}
          />
        ) : (
          <TableView 
            onDefectClick={handleDefectClick}
            points={filteredPoints}
          />
        )}

        <RightDrawer 
          isOpen={isRightDrawerOpen} 
          setIsOpen={setIsRightDrawerOpen}
          defect={selectedDefect}
          onTelemetryPruned={loadData}
        />
      </div>

      <StatusBar 
        viewMode={viewMode} 
        onViewModeToggle={handleViewModeToggle}
        filteredCount={filteredPoints.length}
        totalCount={rawPoints.length}
        lastUpdated={lastUpdated}
        onRefresh={loadData}
      />
    </>
  );
};

export default Dashboard;
