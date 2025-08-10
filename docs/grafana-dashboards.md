# Recommended Grafana Dashboards

## How to Import
1. Go to Grafana (http://192.168.178.99:3000)
2. Click "+" → "Import"
3. Enter the Dashboard ID
4. Select "Prometheus" as the data source
5. Click "Import"

## Essential Dashboards

### 1. **Node Exporter Full** - ID: 1860
- Complete system metrics for all nodes
- CPU, Memory, Disk, Network statistics
- Very comprehensive

### 2. **Kubernetes Cluster Monitoring** - ID: 8588
- Cluster-wide resource usage
- Namespace breakdown
- Pod and container metrics

### 3. **Kubernetes Cluster (Prometheus)** - ID: 6417
- Cluster health overview
- Resource allocation
- Network and storage metrics

### 4. **Node Exporter Server Metrics** - ID: 405
- Simplified node metrics
- Good for quick overview
- Clean layout

### 5. **Kubernetes Pod Metrics** - ID: 747
- Individual pod performance
- Container resource usage
- Restart tracking

### 6. **MetalLB Dashboard** - ID: 14127
- MetalLB specific metrics
- IP pool usage
- Service allocation

## Quick Import Commands

You can also import via API:

```bash
# Import Node Exporter Full dashboard
curl -X POST http://admin:admin@192.168.178.99:3000/api/dashboards/import \
  -H "Content-Type: application/json" \
  -d '{
    "dashboard": {
      "id": 1860,
      "uid": null
    },
    "overwrite": true,
    "inputs": [{
      "name": "DS_PROMETHEUS",
      "type": "datasource",
      "pluginId": "prometheus",
      "value": "Prometheus"
    }]
  }'
```

## Custom Dashboards Already Installed

The following dashboards should already be available:
- **Node Exporter Full** - Basic node metrics
- **MetalLB Overview** - MetalLB component status
- **Kubernetes Cluster Overview** - Cluster health

Check under "Dashboards" → "Browse" in Grafana.